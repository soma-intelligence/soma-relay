import Foundation
import Synchronization

/// Stand-in for UI tests, picked by the launch argument `-uitest-passkey ok|noprf|fail|nocred`.
/// The constants below are a contract: UI tests and the vault seeding tool reuse them.
nonisolated struct FakePasskeyService: PasskeyProviding {
    enum Mode: String, Sendable {
        /// Fixed credential id and fixed PRF outputs.
        case ok
        /// The credential exists but has no PRF: outputs nil, `prfSupported` false.
        case noprf
        /// Every call throws `PasskeyFailure.cancelled`.
        case fail
        /// No passkey on the device: every call throws `PasskeyFailure.noCredential`.
        case nocred
        /// As `ok` for registration and the first assertion of the process, then every assertion
        /// throws `PasskeyFailure.cancelled`: shows that nothing asks for a second assertion.
        case once
    }

    static let launchArgument = "-uitest-passkey"
    /// 16 bytes of 0xC1.
    static let credentialID = Data(repeating: 0xC1, count: 16)
    /// PRF output for `Relay.prfSaltUnlock`: 32 bytes of 0x11.
    static let prfFirst = Data(repeating: 0x11, count: 32)
    /// PRF output for `Relay.prfSaltBackup`: 32 bytes of 0x22.
    static let prfSecond = Data(repeating: 0x22, count: 32)

    let mode: Mode
    private static let assertions = Mutex(0)

    /// The fake when the process was launched with `-uitest-passkey <mode>`, else nil.
    /// Debug builds only: a Release build never takes the fake.
    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> FakePasskeyService? {
        #if !DEBUG
        return nil
        #else
        guard let index = arguments.firstIndex(of: launchArgument), arguments.indices.contains(index + 1),
              let mode = Mode(rawValue: arguments[index + 1]) else { return nil }
        return FakePasskeyService(mode: mode)
        #endif
    }

    func register(userName: String, userHandle: Data) async throws -> PasskeyRegistration {
        switch mode {
        case .ok, .once: PasskeyRegistration(credentialID: Self.credentialID, prfSupported: true)
        case .noprf: PasskeyRegistration(credentialID: Self.credentialID, prfSupported: false)
        case .fail: throw PasskeyFailure.cancelled
        case .nocred: throw PasskeyFailure.noCredential
        }
    }

    func assert(credentialID: Data?) async throws -> PasskeyAssertion {
        let count = Self.assertions.withLock { n in
            n += 1
            return n
        }
        if mode == .once, count > 1 { throw PasskeyFailure.cancelled }
        return switch mode {
        case .ok, .once: PasskeyAssertion(credentialID: Self.credentialID, prfFirst: Self.prfFirst, prfSecond: Self.prfSecond)
        case .noprf: PasskeyAssertion(credentialID: Self.credentialID, prfFirst: nil, prfSecond: nil)
        case .fail: throw PasskeyFailure.cancelled
        case .nocred: throw PasskeyFailure.noCredential
        }
    }
}
