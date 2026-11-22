# Passkey unlock and backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Relay unlocks with one passkey gesture (OnePass or any PRF provider) and a new device restores the Relay identity from that passkey.

**Architecture:** All vault crypto lives once in `relay-core` (`vault` module) and reaches iOS through `relay-ffi` and the web through `relay-wasm`; clients only run the passkey ceremony and move bytes. The node stores opaque blobs under `/v1/vault/{id}`. OnePass answers the PRF extension from a seed derived from each passkey's private key.

**Tech Stack:** Rust (relay-core, relay-node axum + rusqlite, relay-ffi UniFFI, relay-wasm), Swift/SwiftUI iOS 18 (AuthenticationServices, LocalAuthentication), TypeScript + Playwright, OnePass core (Rust) + AutoFill extension (Swift).

**Spec:** [docs/specs/2026-11-22-passkey-unlock-backup.md](../specs/2026-11-22-passkey-unlock-backup.md)

## Global Constraints

- Relying party id `relay.somalabs.me`. AASA app id `M968YV4J8W.me.somalabs.relay`.
- Salts: `first = SHA-256("soma-relay/unlock/v1")`, `second = SHA-256("soma-relay/backup/v1")`.
- `unlock_key = HKDF-SHA256(p_first, salt "", info "soma-relay unlock v1", 32)`; `vault_key = HKDF-SHA256(p_second, salt "", info "soma-relay vault v1", 32)`; `vault_id = hex(SHA-256("soma-relay vault id v1" || credential_id))`.
- Blob: `"RVB1" || nonce(12) || AES-256-GCM(vault_key, nonce, plaintext, aad = vault_id ASCII)`, max 1 MiB.
- PUT signature: Ed25519 over `"relay-vault-v1" || vault_id ASCII || SHA-256(blob)`, headers `X-Relay-Mailbox`, `X-Relay-Sig`.
- Keychain services: `me.somalabs.relay.lock` (check value), `me.somalabs.relay.vault` (vault key), both `AfterFirstUnlockThisDeviceOnly`.
- Relock delays: immediately, 1 min (default), 15 min, 1 h, never.
- Vault retention: 400 days since last write.
- Backup upload debounce: 10 s, plus on going to background.
- UI copy in French, "tu" not used in Relay (existing copy uses "vous"); no em dash anywhere.
- Commits as `Soma Labs <opensource@somalabs.me>`, explicit paths only, no attribution lines, no worktrees.
- OnePass work goes on its own branch from `origin/main` in the OnePass repo (the checkout is on `feat/guarded-kit` with uncommitted files that are not ours: do not touch them; use `git stash` only if the owner agrees, otherwise a separate clone in the scratchpad).

## Deviation from the spec (owner to confirm at plan review)

Spec section 5 stores a synced random `prfSeed` per passkey. This plan derives it instead: `prf_seed = HKDF-SHA256(private_key, salt "", info "onepass webauthn prf v1", 32)`. Same output on every device with no new field, no migration and no sync write during an assertion. The private key is already the passkey's root secret, so exposure is unchanged. Task 9 updates the spec text.

## Review Focus

1. Passkey deleted from OnePass while the lock is on: the assertion fails or is cancelled. Expected: the lock screen offers "Utiliser Face ID / code" (LAContext) and never leaves the user stuck. Test in Task 6.
2. Provider without PRF (registration says `prf` unsupported): Relay must not claim backup is on; the lock uses LAContext; Settings says "Votre gestionnaire ne prend pas en charge la sauvegarde". Test in Task 7.
3. Upload while offline or node 5xx: the dirty flag stays set and the next save or foreground retries; no crash, no lost state. Test in Task 7.
4. Restore with a Relay passkey whose vault does not exist (never backed up, or another node): plain message "Aucune sauvegarde pour ce passkey", onboarding stays usable. Test in Task 8.
5. State over 1 MiB (many contacts, big photo): the photo is dropped first; if still too big, sealing fails with `VaultError::TooLarge` and Settings shows the error instead of silently not backing up. Test in Task 3.

---

### Task 1: Node vault store and routes

**Files:**
- Modify: `crates/relay-node/src/store.rs` (new table `vault(id TEXT PRIMARY KEY, owner BLOB NOT NULL, blob BLOB NOT NULL, updated_at INTEGER NOT NULL)` in the migration list; methods below)
- Create: `crates/relay-node/src/vault.rs` (handlers)
- Modify: `crates/relay-node/src/http.rs:30-44` (routes), `crates/relay-node/src/lib.rs` (mod, retention sweep next to the existing blob sweep)
- Test: `crates/relay-node/tests/node.rs`

**Interfaces:**
- Produces: `Store::put_vault(&self, id: &str, owner: &[u8;16], blob: &[u8], now: i64) -> rusqlite::Result<PutVault>` with `enum PutVault { Written, OwnerMismatch }`; `Store::get_vault(&self, id: &str) -> rusqlite::Result<Option<Vec<u8>>>`; `Store::sweep_vaults(&self, older_than: i64) -> rusqlite::Result<usize>`; constants `MAX_VAULT_BYTES = 1 << 20`, `VAULT_RETENTION_MS = 400 * 86_400_000`.
- Routes: `PUT /v1/vault/{id}` and `GET /v1/vault/{id}`; `id` must be 64 lowercase hex (reuse `valid_sha256_hex`).

- [ ] **Step 1: Write failing tests** in `tests/node.rs`: `vault_roundtrip` (authenticated mailbox PUT then GET returns same bytes, 200), `vault_bad_signature` (403 `bad_signature`), `vault_unknown_mailbox` (403 `unknown_mailbox`), `vault_other_owner` (second mailbox PUT on same id gets 403 `not_owner`, first owner can still overwrite), `vault_too_large` (1 MiB + 1 byte gets 413), `vault_missing` (GET unknown id gets 404), `vault_bad_id` (GET `/v1/vault/xyz` gets 400). Build the signature exactly as in Global Constraints with the test identity helpers already used by the directory tests.
- [ ] **Step 2: Run** `cargo test -p relay-node --test node vault` and see them fail (404 from the catch-all).
- [ ] **Step 3: Implement** store methods, handlers (same header parsing and binding check as `put_handle`, error code `not_owner` for `OwnerMismatch`, body limit `MAX_VAULT_BYTES` via `DefaultBodyLimit::max`), routes before the `/v1/{*rest}` catch-all, and the sweep.
- [ ] **Step 4: Add** `store_sweeps_old_vaults` unit test in `store.rs` (insert at t, sweep at t + retention + 1 removes it, at t + retention keeps it). Run `cargo test -p relay-node`: all PASS. `cargo clippy -p relay-node -- -D warnings` clean.
- [ ] **Step 5: Document** the two routes in `docs/node-protocol.md` and commit `relay-node: encrypted vault blobs for passkey backup`.

### Task 2: AASA, domain and default node URL

**Files:**
- Modify: `crates/relay-node/src/http.rs` (route `GET /.well-known/apple-app-site-association`, `Content-Type: application/json`, body from config `RELAY_AASA_APP_ID`, default `M968YV4J8W.me.somalabs.relay`)
- Modify: `deploy/Caddyfile` (`{$RELAY_HOST}` accepts a list: `{$RELAY_HOSTS}`), `deploy/README.md`
- Modify: `apple/App/AppConfig.swift` and `web/src/net/*` default node URL to `https://relay.somalabs.me` (stored URLs untouched)
- Test: `crates/relay-node/tests/node.rs`

- [ ] **Step 1: Failing test** `aasa_served`: GET returns 200, JSON `{"webcredentials":{"apps":["M968YV4J8W.me.somalabs.relay"]}}`, content type `application/json`, not the SPA index.
- [ ] **Step 2: Run** `cargo test -p relay-node --test node aasa_served`, expect FAIL (SPA HTML).
- [ ] **Step 3: Implement**, run, PASS. Commit `relay-node: apple-app-site-association for relay.somalabs.me`.
- [ ] **Step 4: DNS.** Check for GoDaddy API access (`onepass` MCP search "godaddy"). With access: add `CNAME relay -> somarelay.westus2.cloudapp.azure.com`. Without: ask the owner to add it, and continue with other tasks. Verify: `dig +short relay.somalabs.me` returns the Azure name.
- [ ] **Step 5: Deploy** (recipe in memory `soma-relay.md`): new image tag, `RELAY_HOSTS="somarelay.westus2.cloudapp.azure.com, relay.somalabs.me"` in `~/relay/.env`, `docker compose up -d`. Verify `curl -s https://relay.somalabs.me/.well-known/apple-app-site-association` prints the JSON and `curl -s https://relay.somalabs.me/healthz` is OK.

### Task 3: `relay-core` vault crypto, exposed to Swift and the web

**Files:**
- Create: `crates/relay-core/src/vault.rs`, `docs/vectors/vault-v1.json`
- Modify: `crates/relay-core/src/lib.rs`, `crates/relay-core/src/error.rs` (`VaultError`), `crates/relay-ffi/src/lib.rs`, `crates/relay-wasm/src/lib.rs`
- Test: `crates/relay-core/src/vault.rs` (`#[cfg(test)]`), `crates/relay-ffi/tests` smoke

**Interfaces:**
- Produces (Rust): `pub fn unlock_check(prf_first: &[u8;32]) -> [u8;32]` (= `HMAC-SHA256(unlock_key, "ok")`), `pub fn vault_key(prf_second: &[u8;32]) -> [u8;32]`, `pub fn vault_id(credential_id: &[u8]) -> String`, `pub fn seal_vault(key: &[u8;32], id: &str, plain: &VaultPlain) -> Result<Vec<u8>, VaultError>`, `pub fn open_vault(key: &[u8;32], id: &str, blob: &[u8]) -> Result<VaultPlain, VaultError>`, `pub fn vault_sig_message(id: &str, blob: &[u8]) -> Vec<u8>`, `RelayEngine::sign_vault(&self, id: &str, blob: &[u8]) -> [u8;64]`, `pub const PRF_SALT_UNLOCK: [u8;32]`, `pub const PRF_SALT_BACKUP: [u8;32]`.
- `VaultPlain { v: u8, engine: Vec<u8>, handle: Option<String>, node_url: Option<String>, channels_prefs: Vec<u8>, photo: Option<Vec<u8>> }` (postcard). `VaultError { TooLarge, BadMagic, Decrypt, Parse }`.
- FFI: same names in camelCase on `RelayCoreFactory` / free functions, bytes as `Data`; WASM: `unlockCheck`, `vaultKey`, `vaultId`, `sealVault`, `openVault`, `signVault`, `PRF_SALT_UNLOCK`, `PRF_SALT_BACKUP` (exported getters), `VaultPlain` as a JS object.

- [ ] **Step 1: Failing tests:** `salts_match_spec` (constants equal SHA-256 of the two strings), `vectors_v1` (reads `docs/vectors/vault-v1.json`: given fixed `prf_first`, `prf_second`, `credential_id`, `nonce`, plaintext, expect `unlock_check`, `vault_key`, `vault_id`, blob hex), `seal_open_roundtrip`, `wrong_id_rejected` (open with other id gives `Decrypt`), `bad_magic_rejected`, `too_large_drops_photo_then_fails` (plain with 900 KiB photo + 200 KiB engine seals with `photo: None`; 1.1 MiB engine gives `TooLarge`), `sign_vault_verifies` (signature checks against the identity Ed25519 key over `vault_sig_message`).
- [ ] **Step 2: Run** `cargo test -p relay-core vault`, FAIL (module missing).
- [ ] **Step 3: Implement** with crates already in the workspace (`hkdf`, `sha2`, `hmac`, `aes-gcm`; add to `relay-core/Cargo.toml` if missing). `seal_vault` takes the nonce from the engine RNG; a `seal_vault_with_nonce` `#[cfg(test)]` variant feeds the vectors. Generate the vector file once from the implementation, then hand-check `unlock_check` and `vault_id` with `openssl dgst`/`python3 -I -c` before committing it.
- [ ] **Step 4: Expose** through FFI and WASM, regenerate bindings (`make` targets used for the current builds), add an FFI smoke test (`vault_roundtrip_ffi`) and a WASM `wasm-bindgen-test` roundtrip. Run `cargo test --workspace`: PASS.
- [ ] **Step 5: Commit** `relay-core: vault keys, blob sealing and vectors`.

### Task 4: `.relaykey` v2 (passphrase sealed)

**Files:**
- Modify: `crates/relay-core/src/vault.rs` (`seal_export(passphrase: &str, state: &[u8]) -> String` giving `relaystate2:<b64url(salt16 || nonce12 || ct)>`, Argon2id m=64 MiB, t=3, p=1; `open_export(passphrase: Option<&str>, text: &str) -> Result<Vec<u8>, VaultError>` accepting `relaystate1:` without passphrase and `relaystate2:` with it, new `VaultError::Passphrase`)
- Modify: `apple/App/Model/AppModel.swift:796-803` (`exportIdentity(passphrase:)`), the existing import path, `apple/App/UI/Settings/SettingsView.swift` (passphrase sheet, 2 fields, min 10 chars), web `Settings.tsx` / `Onboarding.tsx` import and export
- Test: Rust unit tests; web `two-instances.spec.ts` extended

- [ ] **Step 1: Failing tests** `export_v2_roundtrip`, `export_v2_wrong_passphrase` (`Passphrase`), `export_v1_still_imports`, `export_v2_needs_passphrase` (None gives `Passphrase`).
- [ ] **Step 2: Run** `cargo test -p relay-core export_`, FAIL.
- [ ] **Step 3: Implement** (`argon2` crate), expose via FFI/WASM, wire both clients. iOS import shows the passphrase field only for `relaystate2:`.
- [ ] **Step 4: Verify** `cargo test -p relay-core`, iOS build (`xcodebuild -scheme SomaRelay -destination 'generic/platform=iOS Simulator' build`), web e2e export-then-import with passphrase in `two-instances.spec.ts`: PASS.
- [ ] **Step 5: Commit** `export: .relaykey v2 sealed with a passphrase`.

### Task 5: iOS passkey service and association

**Files:**
- Create: `apple/App/Core/Passkey/PasskeyService.swift`, `apple/App/Core/Passkey/FakePasskeyService.swift` (selected by launch argument `-uitest-passkey ok|noprf|fail`)
- Modify: `apple/App/SomaRelay.entitlements` (`com.apple.developer.associated-domains` = `webcredentials:relay.somalabs.me`), `apple/project.yml`
- Test: UI tests in Task 6 and 7 use the fake

**Interfaces:**
- Produces:
  ```swift
  protocol PasskeyProviding: Sendable {
      func register(userName: String, userHandle: Data) async throws -> PasskeyRegistration   // credentialID, prfSupported
      func assert(credentialID: Data?) async throws -> PasskeyAssertion                       // credentialID, prfFirst: Data?, prfSecond: Data?
  }
  enum PasskeyFailure: Error { case cancelled, noCredential, notAvailable }
  ```
- `register` requests `prf` (`ASAuthorizationPublicKeyCredentialPRFRegistrationInput.checkForSupport`), `residentKeyPreference .required`, `userVerificationPreference .required`. `assert` passes both salts (`Relay.prfSaltUnlock`, `Relay.prfSaltBackup` from FFI) as `inputValues(first:second:)`, `allowedCredentials` empty when `credentialID == nil`.

- [ ] **Step 1: Implement** the service around `ASAuthorizationController` with a continuation; map `ASAuthorizationError.canceled` to `.cancelled`, "no credentials" to `.noCredential`.
- [ ] **Step 2: Enable** Associated Domains on App ID `me.somalabs.relay` (developer.apple.com, needs the owner signed in to the browser pane) and refresh the provisioning profile. If the owner is not signed in, keep the entitlement and note the blocker; the simulator build still runs with the fake.
- [ ] **Step 3: Verify** iOS build passes; on device later: Settings test in Task 7.
- [ ] **Step 4: Commit** `ios: passkey service with PRF and the relay.somalabs.me association`.

### Task 6: iOS lock screen

**Files:**
- Create: `apple/App/Model/LockController.swift`, `apple/App/UI/Lock/LockView.swift`
- Modify: `apple/App/SomaRelayApp.swift` (overlay + scene phase), `apple/App/UI/Settings/SettingsView.swift` (section "Sécurité": toggle "Verrouiller Relay", picker "Verrouiller après"), `apple/App/Model/AppModel.swift` (`wipe()` clears lock data)
- Test: `apple/UITests/LockUITests.swift`

**Interfaces:**
- Consumes: `PasskeyProviding`, `unlockCheck(prfFirst:)` (FFI).
- Produces: `@MainActor @Observable final class LockController { var isLocked: Bool; var enabled: Bool; var delay: RelockDelay; func unlock() async; func unlockWithDevice() async; func enable() async -> Bool; func disable() async -> Bool; func didEnterBackground(at: Date); func willEnterForeground(at: Date) }`, `enum RelockDelay: Int, CaseIterable { case immediate = 0, oneMinute = 60, fifteenMinutes = 900, oneHour = 3600, never = -1 }` (default `.oneMinute`).
- Behaviour: passkey path compares `unlockCheck(prfFirst)` with Keychain `me.somalabs.relay.lock` in constant time; if no check value or no PRF, uses `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`. On `.cancelled`/`.noCredential`, the view shows "Utiliser Face ID ou le code". Privacy cover shows `LockView` when `scenePhase != .active` and the lock is enabled.

- [ ] **Step 1: Failing UI tests** (fake passkey): `testLockAppearsAtLaunchWhenEnabled`, `testUnlockWithPasskey` (`ok`), `testFallbackWhenPasskeyFails` (`fail`: button "Utiliser Face ID ou le code" visible; simulator enrolled via `xcrun simctl` matching face), `testRelockAfterDelay` (delay immediate, background, foreground: locked), `testWipeClearsLock` (wipe returns to onboarding, no lock screen).
- [ ] **Step 2: Run** `xcodebuild test -scheme SomaRelay -only-testing:SomaRelayUITests/LockUITests -destination 'platform=iOS Simulator,name=iPhone 17'`, FAIL.
- [ ] **Step 3: Implement** controller, view (one button "Déverrouiller", auto-start once at launch), settings section (enabling needs one successful unlock first, disabling needs an unlock).
- [ ] **Step 4: Run** the same command, PASS; take a simulator screenshot of the lock screen in light and dark.
- [ ] **Step 5: Commit** `ios: lock screen with passkey unlock and device fallback`.

### Task 7: iOS backup (create passkey, upload)

**Files:**
- Create: `apple/App/Model/VaultSync.swift`
- Modify: `apple/App/Transport/NodeClient.swift` (or the file holding `publish(handle:)`: `putVault(id:blob:mailbox:signature:)`, `getVault(id:) -> Data?`), `apple/App/Model/AppModel.swift` (`scheduleSave()`/`saveNow()` mark vault dirty; background notification flushes), `apple/App/UI/Settings/SettingsView.swift` ("Protéger avec un passkey" row with status: "Sauvegardé à HH:mm", "En attente du réseau", "Votre gestionnaire ne prend pas en charge la sauvegarde", error text), `apple/App/UI/Onboarding/OnboardingView.swift` (skippable step "Protéger avec un passkey" after name)
- Test: `apple/UITests/BackupUITests.swift`, Rust already covers crypto

**Interfaces:**
- Consumes: Task 3 FFI (`vaultKey`, `vaultId`, `sealVault`, `signVault`), Task 1 routes, Task 5 service, Task 6 `LockController` (writes the check value on setup).
- Produces: `@MainActor final class VaultSync { func setUp(userName: String) async throws -> SetupResult; func markDirty(); func flush() async; var status: VaultStatus }`, `enum SetupResult { case backedUp, lockOnly }` (`lockOnly` when PRF unsupported), `enum VaultStatus { case off, lockOnly, saved(Date), pending, failed(String) }`.
- `setUp`: register, then one assertion to get both PRF outputs (registration outputs are not relied on), store check value and vault key in Keychain, store credential id (`UserDefaults` `passkeyCredentialID`), seal and upload.

- [ ] **Step 1: Failing UI tests** with fake passkey and a local node (`RELAY_NODE_URL` launch env, node from `cargo run -p relay-node`): `testSetupBacksUp` (status shows "Sauvegardé"), `testNoPrfMeansLockOnly` (`noprf`: status text "Votre gestionnaire ne prend pas en charge la sauvegarde"), `testOfflineKeepsPending` (node stopped: status "En attente du réseau"; node restarted, foreground: "Sauvegardé").
- [ ] **Step 2: Run** the UI tests, FAIL.
- [ ] **Step 3: Implement**. Debounce 10 s with a cancellable `Task`; flush on `didEnterBackground` inside `beginBackgroundTask`; dirty flag persisted in `UserDefaults` so a killed app retries on next launch.
- [ ] **Step 4: Run** UI tests, PASS. Check with `curl` that the node holds a blob starting with `RVB1` for the logged `vault_id`.
- [ ] **Step 5: Commit** `ios: passkey backup to the node vault`.

### Task 8: iOS restore at onboarding

**Files:**
- Modify: `apple/App/UI/Onboarding/OnboardingView.swift` (button "Restaurer avec un passkey" under create), `apple/App/Model/AppModel.swift` (`restoreFromPasskey() async throws`)
- Test: `apple/UITests/RestoreUITests.swift`

**Interfaces:**
- Consumes: Task 3 `vaultId`, `vaultKey`, `openVault`; Task 1 GET; Task 5 `assert(credentialID: nil)`; Task 7 `VaultSync` (stores keys after restore); `RelayCoreFactory.restore(state:)`.
- Errors shown: "Aucune sauvegarde pour ce passkey" (404), "Ce passkey ne peut pas ouvrir la sauvegarde" (`Decrypt`), "Pas de réseau" (transport). After success, the banner says "Identité restaurée. Utilisez ce téléphone désormais."

- [ ] **Step 1: Failing UI tests:** `testRestoreBringsBackIdentity` (fake passkey with fixed PRF outputs; seed the local node with a blob made by `relay-core` test helper `make_test_vault` from a known engine; after restore, My card shows the known fingerprint words), `testRestoreMissingVault` (404 message, still on onboarding).
- [ ] **Step 2: Run**, FAIL.
- [ ] **Step 3: Implement**; after restore apply `handle`, `node_url`, channels prefs and photo, then `didLoadCore()`, write lock check, enable lock with default delay.
- [ ] **Step 4: Run**, PASS. Commit `ios: restore identity from a passkey`.

### Task 9: OnePass PRF in core (OnePass repo)

**Files (OnePass repo, branch `feat/passkey-prf` from `origin/main`):**
- Modify: `core/onepass-core/src/webauthn.rs`, `core/onepass-ffi/src/autofill.rs` (`create_passkey`, `passkey_assertion`), `core/onepass-ffi/src/types.rs`
- Modify (soma-relay repo): spec section 5 to the derived seed
- Test: `core/onepass-core/src/webauthn.rs` tests, `core/onepass-ffi/tests/autofill.rs`

**Interfaces:**
- Produces: `pub fn prf_eval(cred: &PasskeyCredential, salt: &[u8]) -> [u8;32]` = `HMAC-SHA256(HKDF-SHA256(private_key, "", "onepass webauthn prf v1", 32), SHA-256("WebAuthn PRF" || 0x00 || salt))`. FFI: `FfiPrfInput { first: Vec<u8>, second: Option<Vec<u8>> }`; `create_passkey(.., prf: Option<FfiPrfInput>)` returns `prf_enabled: true` and `prf: Option<FfiPrfOutput>`; `passkey_assertion(.., prf: Option<FfiPrfInput>)` returns `prf: Option<FfiPrfOutput { first: Vec<u8>, second: Option<Vec<u8>> }>`.

- [ ] **Step 1: Failing tests:** `prf_matches_webauthn_mapping` (fixed private key and salt; expected value computed independently with `python3 -I` hashlib/hmac and pasted as hex), `prf_is_per_credential` (two keys, different outputs), `prf_stable_across_copies` (cloned credential, same output), `assertion_returns_two_outputs`, `assertion_without_prf_input_returns_none`.
- [ ] **Step 2: Run** `cargo test -p onepass-core prf_ && cargo test -p onepass-ffi --test autofill prf`, FAIL.
- [ ] **Step 3: Implement**, regenerate Swift bindings with the repo's existing `make` target.
- [ ] **Step 4: Run** `cargo test -p onepass-core -p onepass-ffi`, PASS. Commit in OnePass `core: WebAuthn PRF for stored passkeys`; in soma-relay commit `spec: OnePass PRF seed derived from the passkey key`.

### Task 10: OnePass AutoFill answers PRF (OnePass repo)

**Files:**
- Modify: `apple/VaultKit/Sources/VaultKit/AutoFill/AutoFillRequest.swift` (`PasskeyRequest.prf: PrfInput?`), `apple/VaultKit/Sources/VaultKit/AutoFill/AutoFillModel.swift`, `apple/AutoFill/CredentialProviderViewController.swift:95-170`
- Test: `apple/VaultKit/Tests/VaultKitTests/AutoFillSessionTests.swift`

- [ ] **Step 1: Failing test** `testPasskeyAssertionCarriesPrfOutputs` (session with a stored passkey and a request carrying two salts returns both outputs equal to `prf_eval`), `testRegistrationReportsPrfEnabled`.
- [ ] **Step 2: Run** `swift test --package-path apple/VaultKit --filter AutoFillSessionTests`, FAIL.
- [ ] **Step 3: Implement**: read `ASPasskeyCredentialRequest.extensionInput` (assertion: `.assertion(input)` with `prf?.inputValues`, `prf?.perCredentialInputValues[credentialID]` taking precedence) and registration `ASPasskeyRegistrationCredentialExtensionInput.prf`; set `ASPasskeyAssertionCredential.extensionOutput = .init(prf: .init(first:second:))` and registration output `prf: .init(isSupported: true, first:second:)`. iOS and macOS share the code.
- [ ] **Step 4: Run** tests, PASS; build the AutoFill scheme for iOS and macOS. Commit `autofill: answer the WebAuthn PRF extension`. Push the branch and open a PR on the OnePass repo (public; CLA check is known to fail on Soma Labs commits, see memory).

### Task 11: Web passkey, backup and restore

**Files:**
- Create: `web/src/net/passkey.ts`, `web/tests/passkey-backup.spec.ts`
- Modify: `web/src/state/relay.ts` (save hook marks vault dirty, debounce 10 s, `visibilitychange` flush), `web/src/net/node.ts` (or the node client file: `putVault`, `getVault`), `web/src/ui/Settings.tsx`, `web/src/ui/Onboarding.tsx`

**Interfaces:**
- Consumes: WASM `vaultKey`, `vaultId`, `sealVault`, `openVault`, `signVault`, salts; Task 1 routes.
- Produces: `registerPasskey(userName: string, userHandle: Uint8Array): Promise<{credentialId: Uint8Array, prf: boolean}>`, `assertPasskey(credentialId?: Uint8Array): Promise<{credentialId: Uint8Array, first?: Uint8Array, second?: Uint8Array}>`, `prfAvailable(): Promise<boolean>`. Vault key kept in IndexedDB next to the engine state (same protection as the state). Passkey UI hidden when `location.hostname !== 'relay.somalabs.me'` and not `localhost`, or when PRF is unavailable.

- [ ] **Step 1: Failing e2e** `passkey-backup.spec.ts` using a CDP virtual authenticator (`WebAuthn.addVirtualAuthenticator` with `protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, hasPrf: true`): create account A and contact B, exchange a message, A sets up the passkey, copy the credential to a new context's authenticator (`WebAuthn.getCredentials` then `addCredential`), restore there, same fingerprint, send a message to B and B receives it. Second test: authenticator with `hasPrf: false` shows "Votre gestionnaire ne prend pas en charge la sauvegarde".
- [ ] **Step 2: Run** `RELAY_NODE_URL=http://127.0.0.1:8099 pnpm e2e passkey-backup`, FAIL. On localhost the RP id is `localhost` (dev only), production uses `relay.somalabs.me`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the full suite `pnpm e2e` locally (all PASS), then `pnpm lint` and `pnpm build`.
- [ ] **Step 5: Commit** `web: passkey backup and restore`.

### Task 12: Ship and record

- [ ] **Step 1:** Rebuild and deploy the node image with the web build (Task 2 recipe). Run `RELAY_NODE_URL=https://relay.somalabs.me pnpm e2e`: all PASS.
- [ ] **Step 2:** Push soma-relay `main`. Bump the iOS build number, archive and upload (needs Associated Domains on the profile, Task 5 Step 2).
- [ ] **Step 3:** Update `README.md` (passkey section) and memory `soma-relay.md` (vault routes, domain, what is device-verified and what is not).
- [ ] **Step 4:** Owner device checks list in the final report: passkey setup with OnePass on the iPhone, unlock after 1 min, restore on a second device, OnePass PRF on macOS Safari.
