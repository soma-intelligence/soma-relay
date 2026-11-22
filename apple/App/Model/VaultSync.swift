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
    }

    static let keychainService = "me.somalabs.relay.vault"
    static let keychainAccount = "vault-key-v1"
    static let dirtyKey = "vaultDirty"
    static let savedAtKey = "vaultSavedAt"
    static let lockOnlyKey = "vaultLockOnly"
    static let userHandleKey = "passkeyUserHandle"
    static let debounce: Duration = .seconds(10)

    private(set) var status: VaultStatus = .off
    /// A setup or an upload is running.
    private(set) var busy = false

    /// Set by `AppModel` right after its own init.
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private let passkeys: any PasskeyProviding
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var hasKey: Bool
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var uploading = false
    @ObservationIgnored private var uploadAgain = false
    /// Bumped by every `markDirty`, so an upload only clears the flag for the state it carried.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let log = Logger(subsystem: "me.somalabs.relay", category: "vault")

    init(passkeys: any PasskeyProviding = PasskeyService.current, defaults: UserDefaults = .standard) {
        self.passkeys = passkeys
        self.defaults = defaults
        hasKey = Self.storedKey() != nil
        status = initialStatus()
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
    func setUp(userName: String) async throws -> SetupResult {
        guard let model, model.vaultCanSeal else { throw SetupError.noIdentity }
        let lock = model.lock
        guard !busy else { throw PasskeyFailure.cancelled }
        busy = true
        defer { busy = false }

        let registration = try await passkeys.register(userName: userName, userHandle: userHandle())
        let assertion = try await passkeys.assert(credentialID: registration.credentialID)
        lock.storeCredential(id: assertion.credentialID)
        if let prfFirst = assertion.prfFirst {
            lock.storeCheck(prfFirst: prfFirst)
        }
        // `prfSupported` from the registration is not relied on: the assertion outputs decide.
        guard let prfSecond = assertion.prfSecond, let key = try? vaultKey(prfSecond: prfSecond),
              Self.storeKey(key)
        else {
            // No PRF: the passkey locks Relay, nothing to encrypt a backup with.
            Self.deleteKey()
            hasKey = false
            dirty = false
            defaults.removeObject(forKey: Self.savedAtKey)
            defaults.set(true, forKey: Self.lockOnlyKey)
            status = .lockOnly
            return .lockOnly
        }
        hasKey = true
        defaults.removeObject(forKey: Self.lockOnlyKey)
        defaults.removeObject(forKey: Self.savedAtKey)
        #if DEBUG
        log.notice("vault id \(vaultId(credentialId: assertion.credentialID), privacy: .public)")
        #endif
        markDirty(debounced: false)
        status = .pending
        await flush()
        return .backedUp
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

    /// Seals the engine state and puts it on the node, if an upload is owed.
    func flush() async {
        guard hasKey, dirty, let model else { return }
        if uploading {
            uploadAgain = true
            return
        }
        uploading = true
        defer { uploading = false }
        repeat {
            uploadAgain = false
            await uploadOnce(model)
        } while uploadAgain && dirty
    }

    private func uploadOnce(_ model: AppModel) async {
        debounceTask?.cancel()
        guard let key = Self.storedKey(), let credential = model.lock.credentialID,
              let snapshot = model.vaultSnapshot()
        else { return }
        let carried = generation
        let id = vaultId(credentialId: credential)
        let blob: Data
        do {
            blob = try sealVault(key: key, id: id, plain: snapshot.plain)
        } catch {
            // The generated `VaultError` is internal to RelayCore: read the case by reflection.
            status = .failed(String(reflecting: error).contains("TooLarge")
                ? "Sauvegarde trop lourde pour le nœud."
                : "Sauvegarde impossible à chiffrer.")
            return
        }
        guard let signature = snapshot.sign(id, blob) else {
            status = .failed("Sauvegarde impossible à signer.")
            return
        }
        do {
            try await model.node.putVault(id: id, blob: blob, mailbox: snapshot.mailbox, signature: signature)
            if generation == carried { dirty = false }
            let now = Date()
            defaults.set(now.timeIntervalSince1970, forKey: Self.savedAtKey)
            status = .saved(now)
        } catch {
            switch error {
            case .network, .unavailable, .refused(code: "unknown_mailbox"), .refused(code: "rate_limited"):
                // Kept for the next node connection (the WebSocket auth binds the mailbox).
                status = .pending
            case .refused(let code):
                status = .failed(Self.message(refused: code))
            }
        }
    }

    // MARK: Wipe

    /// Emergency wipe: vault key, dirty flag and the other backup state go.
    func reset() {
        debounceTask?.cancel()
        debounceTask = nil
        Self.deleteKey()
        hasKey = false
        for key in [Self.dirtyKey, Self.savedAtKey, Self.lockOnlyKey, Self.userHandleKey] {
            defaults.removeObject(forKey: key)
        }
        status = .off
    }

    // MARK: Text

    /// The Settings row status.
    var statusText: String {
        switch status {
        case .off: ""
        case .lockOnly: "Votre gestionnaire ne prend pas en charge la sauvegarde"
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
        default: "Passkey impossible à créer pour le moment."
        }
    }

    // MARK: Keychain

    private static func storedKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func storeKey(_ key: Data) -> Bool {
        deleteKey()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteKey() {
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
