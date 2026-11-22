import Foundation
import LocalAuthentication
import Observation
import RelayCore
import Security

/// How long Relay stays open in the background before it locks again.
enum RelockDelay: Int, CaseIterable, Identifiable {
    case immediate = 0
    case oneMinute = 60
    case fifteenMinutes = 900
    case oneHour = 3600
    case never = -1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .immediate: "Immédiatement"
        case .oneMinute: "Après 1 minute"
        case .fifteenMinutes: "Après 15 minutes"
        case .oneHour: "Après 1 heure"
        case .never: "Jamais"
        }
    }
}

/// Face ID, Touch ID or the device passcode (`.deviceOwnerAuthentication`).
protocol DeviceAuthenticating: Sendable {
    func authenticate(reason: String) async -> Bool
}

nonisolated struct PlatformDeviceAuth: DeviceAuthenticating {
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// UI tests only (Debug builds): `-uitest-deviceauth ok|fail` answers without LAContext.
nonisolated struct FakeDeviceAuth: DeviceAuthenticating {
    static let launchArgument = "-uitest-deviceauth"
    let succeeds: Bool

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> FakeDeviceAuth? {
        guard AppConfig.demoAllowed, let index = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(index + 1) else { return nil }
        switch arguments[index + 1] {
        case "ok": return FakeDeviceAuth(succeeds: true)
        case "fail": return FakeDeviceAuth(succeeds: false)
        default: return nil
        }
    }

    func authenticate(reason: String) async -> Bool { succeeds }
}

/// The lock screen gate (spec section 2). A UI gate only: `SecretBox` keeps its key, so
/// background fetch, notifications and the mesh go on while Relay is locked.
///
/// Passkey path: when a check value is stored, an assertion with the PRF extension gives
/// `prfFirst`; `unlockCheck(prfFirst)` must equal the Keychain value (constant time). No check
/// value, or a passkey without PRF: `LAContext` with `.deviceOwnerAuthentication`.
@MainActor @Observable
final class LockController {
    static let keychainService = "me.somalabs.relay.lock"
    static let keychainAccount = "unlock-check-v1"
    static let enabledKey = "lockEnabled"
    static let delayKey = "lockDelay"
    static let credentialKey = "passkeyCredentialID"
    static let reason = "Déverrouiller Soma Relay"

    /// The lock screen is up.
    var isLocked: Bool
    /// The lock is on. Change it with `enable()` / `disable()`, which need an unlock.
    private(set) var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.enabledKey) }
    }
    var delay: RelockDelay {
        didSet { defaults.set(delay.rawValue, forKey: Self.delayKey) }
    }
    /// The passkey was cancelled or is missing: the lock screen offers device authentication.
    private(set) var showsDeviceFallback = false
    /// Last attempt failed (wrong passkey, device auth refused).
    private(set) var failed = false
    /// An unlock is running (button disabled, no second ceremony).
    private(set) var busy = false

    @ObservationIgnored private let passkeys: any PasskeyProviding
    @ObservationIgnored private let device: any DeviceAuthenticating
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var backgroundedUptime: UInt64?
    /// UI tests only (Debug): `-uitest-clockskew <seconds>` moves the wall clock seen on return.
    @ObservationIgnored private let wallClockSkew: TimeInterval
    @ObservationIgnored private var autoStarted = false

    init(
        passkeys: any PasskeyProviding = PasskeyService.current,
        device: any DeviceAuthenticating = FakeDeviceAuth.fromLaunchArguments() ?? PlatformDeviceAuth(),
        defaults: UserDefaults = .standard
    ) {
        self.passkeys = passkeys
        self.device = device
        self.defaults = defaults
        wallClockSkew = Self.debugClockSkew()
        let on = defaults.bool(forKey: Self.enabledKey)
        enabled = on
        isLocked = on
        delay = defaults.object(forKey: Self.delayKey) == nil
            ? .oneMinute
            : RelockDelay(rawValue: defaults.integer(forKey: Self.delayKey)) ?? .oneMinute
        if AppConfig.demoAllowed, ProcessInfo.processInfo.arguments.contains("-uitest-lockseed"),
           FakePasskeyService.fromLaunchArguments() != nil {
            storeCredential(id: FakePasskeyService.credentialID)
            storeCheck(prfFirst: FakePasskeyService.prfFirst)
        }
    }

    // MARK: Unlock

    /// The first appearance of the lock screen at launch starts the assertion by itself, once.
    func autoStartIfNeeded() async {
        guard isLocked, !autoStarted else { return }
        autoStarted = true
        await unlock()
    }

    /// "Déverrouiller": passkey when one is set up, else device authentication.
    func unlock() async {
        guard isLocked, !busy else { return }
        busy = true
        defer { busy = false }
        failed = false
        switch await passkeyThenDevice(fallBackOnPasskeyFailure: false) {
        case .success: open()
        case .needsFallback: showsDeviceFallback = true
        case .failure: failed = true
        }
    }

    /// "Utiliser Face ID ou le code".
    func unlockWithDevice() async {
        guard isLocked, !busy else { return }
        busy = true
        defer { busy = false }
        failed = false
        if await device.authenticate(reason: Self.reason) {
            open()
        } else {
            failed = true
        }
    }

    private func open() {
        isLocked = false
        showsDeviceFallback = false
        failed = false
    }

    // MARK: Settings

    /// Turns the lock on after one successful unlock, so nobody locks themselves out.
    func enable() async -> Bool {
        guard !enabled else { return true }
        guard await authenticateForSettings() else { return false }
        enabled = true
        return true
    }

    /// Turns the lock on right after passkey setup, without another ceremony: the setup's own
    /// assertion (user verification required) gave `prfFirst`, and it must match the check value
    /// `storeCheck(prfFirst:)` has just stored. Any mismatch or a missing check value refuses.
    func enable(afterVerifiedAssertion prfFirst: Data) -> Bool {
        guard !enabled else { return true }
        guard let expected = Self.storedCheck(), let check = try? unlockCheck(prfFirst: prfFirst),
              Self.constantTimeEqual(check, expected)
        else { return false }
        enabled = true
        return true
    }

    /// Turns the lock off; needs an unlock too.
    func disable() async -> Bool {
        guard enabled else { return true }
        guard await authenticateForSettings() else { return false }
        enabled = false
        isLocked = false
        return true
    }

    private func authenticateForSettings() async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        return await passkeyThenDevice(fallBackOnPasskeyFailure: true) == .success
    }

    // MARK: Scene phase

    func didEnterBackground(at date: Date, uptime: UInt64 = LockController.monotonicNow()) {
        guard enabled, backgroundedAt == nil else { return }
        backgroundedAt = date
        backgroundedUptime = uptime
    }

    func willEnterForeground(at date: Date, uptime: UInt64 = LockController.monotonicNow()) {
        guard let since = backgroundedAt else { return }
        let sinceUptime = backgroundedUptime
        backgroundedAt = nil
        backgroundedUptime = nil
        guard enabled else { return }
        let wall = date.addingTimeInterval(wallClockSkew).timeIntervalSince(since)
        let monotonic = sinceUptime.map { uptime >= $0 ? TimeInterval(uptime - $0) / 1e9 : -1 }
        if Self.shouldRelock(delay: delay, wallElapsed: wall, monotonicElapsed: monotonic) {
            isLocked = true
            showsDeviceFallback = false
            failed = false
        }
    }

    /// Relock rule. The monotonic clock counts sleep and ignores clock changes; the wall clock is
    /// the fallback. Any sign of tampering (negative elapsed time on either clock) or either clock
    /// past the delay locks.
    nonisolated static func shouldRelock(delay: RelockDelay, wallElapsed: TimeInterval, monotonicElapsed: TimeInterval?) -> Bool {
        guard delay != .never else { return false }
        let limit = TimeInterval(delay.rawValue)
        if wallElapsed < 0 || wallElapsed >= limit { return true }
        if let monotonicElapsed, monotonicElapsed < 0 || monotonicElapsed >= limit { return true }
        return false
    }

    /// Nanoseconds on `CLOCK_MONOTONIC` (Darwin: keeps counting while the device sleeps).
    nonisolated static func monotonicNow() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC)
    }

    // MARK: Stored passkey data (single writer)

    /// Stores `unlockCheck(prfFirst)` in the Keychain (`me.somalabs.relay.lock`, this device only).
    /// Task 7 calls it right after creating the passkey.
    @discardableResult
    func storeCheck(prfFirst: Data) -> Bool {
        guard let check = try? unlockCheck(prfFirst: prfFirst) else { return false }
        Self.deleteCheck()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: check,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// The credential id used for `allowCredentials`.
    func storeCredential(id: Data) {
        defaults.set(id, forKey: Self.credentialKey)
    }

    var credentialID: Data? { defaults.data(forKey: Self.credentialKey) }

    /// Wipe: check value, credential id and lock settings go; the lock is off.
    func reset() {
        Self.deleteCheck()
        for key in [Self.credentialKey, Self.enabledKey, Self.delayKey] { defaults.removeObject(forKey: key) }
        enabled = false
        isLocked = false
        delay = .oneMinute
        showsDeviceFallback = false
        failed = false
        backgroundedAt = nil
        backgroundedUptime = nil
    }

    // MARK: Internals

    private enum Outcome: Equatable { case success, needsFallback, failure }

    private func passkeyThenDevice(fallBackOnPasskeyFailure: Bool) async -> Outcome {
        guard let expected = Self.storedCheck() else {
            // No passkey set up yet: device authentication only.
            return await device.authenticate(reason: Self.reason) ? .success : .failure
        }
        do {
            let assertion = try await passkeys.assert(credentialID: credentialID)
            guard let prfFirst = assertion.prfFirst else {
                // The provider has no PRF: device authentication.
                return await device.authenticate(reason: Self.reason) ? .success : .failure
            }
            guard let check = try? unlockCheck(prfFirst: prfFirst) else { return .failure }
            return Self.constantTimeEqual(check, expected) ? .success : .failure
        } catch PasskeyFailure.notAvailable {
            return await device.authenticate(reason: Self.reason) ? .success : .failure
        } catch {
            // Cancelled or no credential: never forget the credential id or turn the lock off.
            if fallBackOnPasskeyFailure {
                return await device.authenticate(reason: Self.reason) ? .success : .failure
            }
            return .needsFallback
        }
    }

    private static func debugClockSkew(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> TimeInterval {
        #if DEBUG
        guard let index = arguments.firstIndex(of: "-uitest-clockskew"), arguments.indices.contains(index + 1) else { return 0 }
        return TimeInterval(arguments[index + 1]) ?? 0
        #else
        return 0
        #endif
    }

    nonisolated static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    private static func storedCheck() -> Data? {
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

    private static func deleteCheck() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
