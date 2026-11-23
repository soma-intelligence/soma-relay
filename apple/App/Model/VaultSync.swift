import Foundation
import Observation
import os
import RelayCore
import Security
import UIKit

/// Passkey backup to the node vault (spec section 3).
///
/// `setUp` creates the passkey, runs one assertion for both PRF outputs, hands the unlock check
/// value and the credential id to `LockController` (their single writer), keeps `vault_key` in
/// the Keychain and uploads the sealed engine state. After that every engine save marks the vault
/// dirty; the upload runs 10 s after the last save, when Relay goes to the background, after a
/// background fetch, and again whenever the node link comes back while an upload is owed.
///
/// The user handle given to the passkey is 16 random bytes in UserDefaults `passkeyUserHandle`:
/// the engine state has no field for app metadata.
@MainActor @Observable
final class VaultSync {
    enum SetupResult: Equatable { case backedUp, lockOnly }

    enum VaultStatus: Equatable {
        /// No passkey backup.
        case off
        /// A passkey without PRF: it locks Relay but cannot encrypt a backup.
        case lockOnly
        /// Last upload accepted by the node.
        case saved(Date)
        /// An upload is owed and the node could not take it yet.
        case pending
        /// The node refused the backup for good (message for the person).
        case failed(String)
    }

    enum SetupError: Error, Equatable {
        /// No identity yet, or the test core (no vault).
        case noIdentity
        /// The PRF output could not become a vault key (wrong length).
        case badPRF
        /// The vault key could not be written to the Keychain (OSStatus).
        case keychain(Int32)
    }

    /// Tests point these at a scratch item so they never touch the app's own key.
    nonisolated(unsafe) static var keychainService = "me.somalabs.relay.vault"
    static let keychainAccount = "vault-key-v1"
    static let dirtyKey = "vaultDirty"
    static let savedAtKey = "vaultSavedAt"
    static let lockOnlyKey = "vaultLockOnly"
    static let userHandleKey = "passkeyUserHandle"
    /// Non-secret "backup on" flag: the vault key is readable only after the first unlock since
    /// boot, so whether a backup exists must not depend on reading it.
    static let enabledKey = "vaultEnabled"
    static let debounce: Duration = .seconds(10)

    private(set) var status: VaultStatus = .off
    /// A setup or an upload is running.
    private(set) var busy = false

    /// Set by `AppModel` right after its own init.
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private let passkeys: any PasskeyProviding
    @ObservationIgnored private let defaults: UserDefaults
    /// Tests only: a lock other than the model's.
    @ObservationIgnored private let lockOverride: LockController?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    /// The upload in flight; every `flush` caller awaits it rather than returning early.
    @ObservationIgnored private var uploadTask: Task<Bool, Never>?
    /// Generation carried by the upload in flight.
    @ObservationIgnored private var inFlightGeneration = 0
    /// Bumped by every `markDirty`, so an upload only clears the flag for the state it carried.
    @ObservationIgnored private var generation = 0
    /// Bumped by `reset()`: an upload that finishes after a wipe writes nothing.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private let log = Logger(subsystem: "me.somalabs.relay", category: "vault")

    init(passkeys: any PasskeyProviding = PasskeyService.current, defaults: UserDefaults = .standard, lock: LockController? = nil) {
        self.lockOverride = lock
        self.passkeys = passkeys
        self.defaults = defaults
        // Reinstall: UserDefaults is wiped, the Keychain is kept. A surviving key is resurrected only
        // with its credential id; without one the key is an orphan (nothing could unseal or
        // upload with it) and goes.
        // `.locked` (before the first unlock since boot): nothing is decided, nothing is deleted.
        if !defaults.bool(forKey: Self.enabledKey), case .found = Self.readKey() {
            if defaults.data(forKey: LockController.credentialKey) != nil {
                defaults.set(true, forKey: Self.enabledKey)
            } else {
                Self.deleteKey()
            }
        }
        status = initialStatus()
    }

    /// A backup is set up (vault key stored). Does not read the Keychain.
    private var hasKey: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    private var dirty: Bool {
        get { defaults.bool(forKey: Self.dirtyKey) }
        set { defaults.set(newValue, forKey: Self.dirtyKey) }
    }

    private var savedAt: Date? {
        defaults.object(forKey: Self.savedAtKey) == nil ? nil : Date(timeIntervalSince1970: defaults.double(forKey: Self.savedAtKey))
    }

    private func initialStatus() -> VaultStatus {
        if hasKey {
            if dirty { return .pending }
            return savedAt.map(VaultStatus.saved) ?? .pending
        }
        return defaults.bool(forKey: Self.lockOnlyKey) ? .lockOnly : .off
    }

    // MARK: Setup

    /// Creates the passkey and the first backup. Passkey failures (`PasskeyFailure`) are thrown
    /// as they are; an upload the node cannot take yet leaves the status at `.pending`.
    /// With `enableLock`, the lock goes on too: through the setup's own PRF assertion when there
    /// is one (no further prompt), else through device authentication.
    func setUp(userName: String, enableLock: Bool = false) async throws -> SetupResult {
        guard let model, model.vaultCanSeal else { throw SetupError.noIdentity }
        let lock = lockOverride ?? model.lock
        guard !busy else { throw PasskeyFailure.cancelled }
        busy = true
        defer { busy = false }

        let registration = try await passkeys.register(userName: userName, userHandle: userHandle())
        let assertion = try await passkeys.assert(credentialID: registration.credentialID)
        // Nothing of the new passkey is stored until the vault key is: a failure before that leaves
        // the previous credential id, check value and key (if any) as they were, never a mix.
        // `prfSupported` from the registration is not relied on: the assertion outputs decide.
        guard let prfSecond = assertion.prfSecond else {
            // No PRF: the passkey locks Relay, nothing to encrypt a backup with.
            lock.storeCredential(id: assertion.credentialID)
            let checkStored = assertion.prfFirst.map { lock.storeCheck(prfFirst: $0) } ?? false
            Self.deleteKey()
            hasKey = false
            dirty = false
            defaults.removeObject(forKey: Self.savedAtKey)
            defaults.set(true, forKey: Self.lockOnlyKey)
            status = .lockOnly
            if enableLock { await turnOnLock(lock, prfFirst: checkStored ? assertion.prfFirst : nil, model: model) }
            return .lockOnly
        }
        guard let key = try? vaultKey(prfSecond: prfSecond) else { throw SetupError.badPRF }
        let written = Self.storeKey(key)
        guard written == errSecSuccess else {
            // `storeKey` removed any older key first: no backup is on any more.
            hasKey = false
            dirty = false
            status = .off
            throw SetupError.keychain(written)
        }
        lock.storeCredential(id: assertion.credentialID)
        let checkStored = assertion.prfFirst.map { lock.storeCheck(prfFirst: $0) } ?? false
        hasKey = true
        defaults.removeObject(forKey: Self.lockOnlyKey)
        defaults.removeObject(forKey: Self.savedAtKey)
        #if DEBUG
        log.notice("vault id \(vaultId(credentialId: assertion.credentialID), privacy: .public)")
        #endif
        markDirty(debounced: false)
        status = .pending
        if enableLock { await turnOnLock(lock, prfFirst: checkStored ? assertion.prfFirst : nil, model: model) }
        await flush()
        return .backedUp
    }

    /// The setup's verified assertion counts as the unlock when it gave the matching `prfFirst`.
    /// A passkey without PRF proves nothing to the lock: device authentication then.
    private func turnOnLock(_ lock: LockController, prfFirst: Data?, model: AppModel) async {
        let on = if let prfFirst { lock.enable(afterVerifiedAssertion: prfFirst) } else { await lock.enable() }
        if !on { model.banner = "Verrouillage non activé : le déverrouillage a échoué." }
    }

    /// Restore on a new phone: the vault this key opened becomes this phone's backup, so later
    /// saves keep going to the same vault id. Uploads the restored state once right away.
    func adoptRestored(key: Data) {
        let written = Self.storeKey(key)
        guard written == errSecSuccess else {
            hasKey = false
            dirty = false
            status = .failed(Self.message(setup: SetupError.keychain(written)))
            return
        }
        hasKey = true
        defaults.removeObject(forKey: Self.lockOnlyKey)
        defaults.removeObject(forKey: Self.savedAtKey)
        markDirty(debounced: false)
        status = .pending
        Task { await flush() }
    }

    /// 16 random bytes, made once and kept until a wipe.
    private func userHandle() -> Data {
        if let existing = defaults.data(forKey: Self.userHandleKey), existing.count == 16 { return existing }
        var bytes = Data(count: 16)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        defaults.set(bytes, forKey: Self.userHandleKey)
        return bytes
    }

    // MARK: Sync

    /// The engine state changed: upload it 10 s after the last change.
    func markDirty() { markDirty(debounced: true) }

    private func markDirty(debounced: Bool) {
        guard hasKey else { return }
        dirty = true
        generation += 1
        debounceTask?.cancel()
        guard debounced else { return }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Node link back, app active again: upload now if one is owed.
    func retryIfOwed() {
        guard hasKey, dirty else { return }
        Task { await flush() }
    }

    /// Going to the background: upload inside a background task so iOS gives it time.
    func flushInBackground() {
        guard hasKey, dirty else { return }
        debounceTask?.cancel()
        let task = BackgroundTask()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "vault-upload") { task.end() }
        Task {
            await flush()
            task.end()
        }
    }

    /// One `beginBackgroundTask` window, ended once (by the upload or by iOS).
    private final class BackgroundTask {
        var id = UIBackgroundTaskIdentifier.invalid

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    /// Seals the engine state and puts it on the node, if an upload is owed. Returns once the
    /// state current at the call is on the node, or an upload attempt for it has ended. A caller
    /// that finds an upload in flight waits for it, then uploads again if a newer state is owed.
    func flush() async {
        while true {
            if let running = uploadTask {
                let carried = inFlightGeneration
                _ = await running.value
                // That upload carried this caller's state unless a save came after it started.
                guard dirty, generation != carried else { return }
                continue
            }
            guard hasKey, dirty, let model else { return }
            inFlightGeneration = generation
            let task = Task { [weak self] () -> Bool in
                guard let self else { return false }
                let ok = await self.uploadOnce(model)
                self.uploadTask = nil
                return ok
            }
            uploadTask = task
            // Stop on a failed attempt (the next trigger retries); go again for a newer state.
            guard await task.value, dirty else { return }
        }
    }

    /// One attempt. True when the node took the blob.
    private func uploadOnce(_ model: AppModel) async -> Bool {
        debounceTask?.cancel()
        let key: Data
        switch Self.readKey() {
        case .found(let data): key = data
        case .locked:
            // Before the first unlock since boot: keep it owed.
            status = .pending
            return false
        case .missing:
            status = .failed("Clé de sauvegarde introuvable. Recrée ton passkey.")
            return false
        }
        guard let credential = model.lock.credentialID else {
            status = .failed("Passkey introuvable. Recrée ton passkey.")
            return false
        }
        guard let snapshot = model.vaultSnapshot() else {
            status = .failed("Aucune identité à sauvegarder.")
            return false
        }
        let carried = generation
        let started = epoch
        let id = vaultId(credentialId: credential)
        let blob: Data
        do {
            blob = try sealVault(key: key, id: id, plain: snapshot.plain)
        } catch {
            // The generated `VaultError` is internal to RelayCore: read the case by reflection.
            status = .failed(String(reflecting: error).contains("TooLarge")
                ? "Sauvegarde trop lourde pour le nœud."
                : "Sauvegarde impossible à chiffrer.")
            return false
        }
        guard let signature = snapshot.sign(id, blob) else {
            status = .failed("Sauvegarde impossible à signer.")
            return false
        }
        do {
            try await model.node.putVault(id: id, blob: blob, mailbox: snapshot.mailbox, signature: signature)
            // Wiped while the PUT ran: nothing of this backup may come back.
            guard epoch == started else { return false }
            let now = Date()
            defaults.set(now.timeIntervalSince1970, forKey: Self.savedAtKey)
            if generation == carried {
                dirty = false
                status = .saved(now)
            } else {
                // A newer state is owed already.
                status = .pending
            }
            return true
        } catch {
            guard epoch == started else { return false }
            switch error {
            case .network, .unavailable, .refused(code: "unknown_mailbox"), .refused(code: "rate_limited"):
                // Kept for the next node connection (the WebSocket auth binds the mailbox).
                status = .pending
            case .refused(let code):
                status = .failed(Self.message(refused: code))
            }
            return false
        }
    }

    // MARK: Wipe

    /// Emergency wipe: vault key, dirty flag and the other backup state go.
    func reset() {
        debounceTask?.cancel()
        debounceTask = nil
        epoch += 1
        Self.deleteKey()
        for key in [Self.enabledKey, Self.dirtyKey, Self.savedAtKey, Self.lockOnlyKey, Self.userHandleKey] {
            defaults.removeObject(forKey: key)
        }
        status = .off
    }

    // MARK: Text

    /// The Settings row status.
    var statusText: String {
        switch status {
        case .off: ""
        case .lockOnly: "Ton gestionnaire ne prend pas en charge la sauvegarde"
        case .saved(let date): "Sauvegardé à " + Self.timeFormatter.string(from: date)
        case .pending: "En attente du réseau"
        case .failed(let message): message
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func message(refused code: String) -> String {
        switch code {
        case "not_owner": "Ce passkey sauvegarde déjà une autre identité sur ce nœud."
        case "bad_signature": "Le nœud a refusé la signature de la sauvegarde."
        case "too_large": "Sauvegarde trop lourde pour le nœud."
        default: "Sauvegarde refusée par le nœud (\(code))."
        }
    }

    /// Why the passkey step did not finish.
    static func message(setup error: Error) -> String {
        switch error {
        case PasskeyFailure.cancelled: "Création du passkey annulée."
        case PasskeyFailure.noCredential: "Aucun passkey n'a été créé."
        case PasskeyFailure.notAvailable: "Les passkeys ne sont pas disponibles sur cet appareil."
        case SetupError.keychain(let code): "Impossible d'enregistrer la clé de sauvegarde (\(code))."
        case SetupError.badPRF: "Ton gestionnaire a renvoyé une clé illisible."
        default: "Passkey impossible à créer pour le moment."
        }
    }

    // MARK: Keychain

    enum KeyRead { case found(Data), locked, missing }

    /// `.locked`: the item exists but cannot be read yet (before the first unlock since boot).
    static func readKey() -> KeyRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess: return (item as? Data).map(KeyRead.found) ?? .missing
        case errSecInteractionNotAllowed: return .locked
        default: return .missing
        }
    }

    static func storeKey(_ key: Data) -> OSStatus {
        deleteKey()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(add as CFDictionary, nil)
    }

    static func keyExists() -> Bool {
        if case .missing = readKey() { return false }
        return true
    }

    static func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// What goes in the vault, read from the model at upload time.
struct VaultSnapshot {
    let plain: VaultPlain
    let mailbox: String
    let sign: (String, Data) -> Data?
}

extension AppModel {
    /// The real core is loaded (the test core and demo data have no vault).
    var vaultCanSeal: Bool { core != nil && !demo && usesRealCore }

    /// Passkey user name: the node handle when there is one, else the display name.
    var passkeyUserName: String { handle.isEmpty ? displayName : handle }

    func vaultSnapshot() -> VaultSnapshot? {
        guard vaultCanSeal, let core else { return nil }
        let prefs = (try? JSONEncoder().encode(UserDefaults.standard.stringArray(forKey: "channels") ?? [])) ?? Data()
        let plain = VaultPlain(
            engine: core.exportState(),
            handle: handle.isEmpty ? nil : handle,
            nodeUrl: nodeEnabled ? nodeURL : nil,
            channelsPrefs: prefs,
            // At most 24 KiB (ProfilePhoto), under the 64 KiB the spec allows.
            photo: db.value(for: "avatar:" + Self.me))
        return VaultSnapshot(plain: plain, mailbox: core.mailboxHex()) { id, blob in core.signVault(id: id, blob: blob) }
    }
}
