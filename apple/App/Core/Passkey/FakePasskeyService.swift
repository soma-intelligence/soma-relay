import Foundation

/// Stand-in for UI tests, picked by the launch argument `-uitest-passkey ok|noprf|fail`.
/// The constants below are a contract: UI tests and the vault seeding tool reuse them.
nonisolated struct FakePasskeyService: PasskeyProviding {
    enum Mode: String, Sendable {
        /// Fixed credential id and fixed PRF outputs.
        case ok
        /// The credential exists but has no PRF: outputs nil, `prfSupported` false.
        case noprf
        /// Every call throws `PasskeyFailure.cancelled`.
        case fail
    }

    static let launchArgument = "-uitest-passkey"
    /// 16 bytes of 0xC1.
    static let credentialID = Data(repeating: 0xC1, count: 16)
    /// PRF output for `Relay.prfSaltUnlock`: 32 bytes of 0x11.
    static let prfFirst = Data(repeating: 0x11, count: 32)
    /// PRF output for `Relay.prfSaltBackup`: 32 bytes of 0x22.
    static let prfSecond = Data(repeating: 0x22, count: 32)

    let mode: Mode

    /// The fake when the process was launched with `-uitest-passkey <mode>`, else nil.
    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> FakePasskeyService? {
        guard let index = arguments.firstIndex(of: launchArgument), arguments.indices.contains(index + 1),
              let mode = Mode(rawValue: arguments[index + 1]) else { return nil }
        return FakePasskeyService(mode: mode)
    }

    func register(userName: String, userHandle: Data) async throws -> PasskeyRegistration {
        switch mode {
        case .ok: PasskeyRegistration(credentialID: Self.credentialID, prfSupported: true)
        case .noprf: PasskeyRegistration(credentialID: Self.credentialID, prfSupported: false)
        case .fail: throw PasskeyFailure.cancelled
        }
    }

    func assert(credentialID: Data?) async throws -> PasskeyAssertion {
        switch mode {
        case .ok: PasskeyAssertion(credentialID: Self.credentialID, prfFirst: Self.prfFirst, prfSecond: Self.prfSecond)
        case .noprf: PasskeyAssertion(credentialID: Self.credentialID, prfFirst: nil, prfSecond: nil)
        case .fail: throw PasskeyFailure.cancelled
        }
    }
}
