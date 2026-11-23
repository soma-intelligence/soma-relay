import AuthenticationServices
import CryptoKit
import Foundation
import RelayCore
import UIKit

/// Relay-wide values that come from the Rust core.
nonisolated enum Relay {
    /// PRF salt of the unlock output, `SHA-256("soma-relay/unlock/v1")` (relay-core).
    static let prfSaltUnlock: Data = RelayCore.prfSaltUnlock()
    /// PRF salt of the backup output, `SHA-256("soma-relay/backup/v1")` (relay-core).
    static let prfSaltBackup: Data = RelayCore.prfSaltBackup()
    /// WebAuthn relying party, bound to the app by `webcredentials:hushrelay.app`.
    static let passkeyRelyingParty = "hushrelay.app"
}

/// Result of a passkey registration.
nonisolated struct PasskeyRegistration: Sendable, Equatable {
    let credentialID: Data
    /// The authenticator reported PRF support (`hmac-secret`) for this credential.
    let prfSupported: Bool
}

/// Result of a passkey assertion. `prfFirst` is the output for `Relay.prfSaltUnlock`,
/// `prfSecond` the output for `Relay.prfSaltBackup`; both nil when the credential has no PRF.
nonisolated struct PasskeyAssertion: Sendable, Equatable {
    let credentialID: Data
    let prfFirst: Data?
    let prfSecond: Data?
}

nonisolated enum PasskeyFailure: Error, Sendable, Equatable {
    /// The person dismissed the system sheet.
    case cancelled
    /// No passkey for hushrelay.app on this device (or the one asked for is gone).
    case noCredential
    /// Passkeys cannot run here (no association, no passcode, request refused, unknown error).
    case notAvailable
}

protocol PasskeyProviding: Sendable {
    func register(userName: String, userHandle: Data) async throws -> PasskeyRegistration
    /// `allowCrossDevice`: also offer passkeys from another device (QR code, nearby phone).
    /// Restore on a new phone needs it; unlock and setup keep to this device's passkeys.
    func assert(credentialID: Data?, allowCrossDevice: Bool) async throws -> PasskeyAssertion
}

extension PasskeyProviding {
    /// This device's passkeys only (unlock, setup).
    func assert(credentialID: Data?) async throws -> PasskeyAssertion {
        try await assert(credentialID: credentialID, allowCrossDevice: false)
    }
}

/// The service the app uses: the fake when launched with `-uitest-passkey ok|noprf|fail|nocred`,
/// else the platform passkey service.
enum PasskeyService {
    static let current: any PasskeyProviding = FakePasskeyService.fromLaunchArguments() ?? PlatformPasskeyService()
}

/// Platform passkeys (iCloud Keychain or another provider) on hushrelay.app with the PRF extension.
/// Nothing is verified server side: the challenge is random and only the PRF outputs are used.
final class PlatformPasskeyService: PasskeyProviding {
    /// A `.canceled` error that arrives faster than this, on an assertion run with
    /// `preferImmediatelyAvailableCredentials`, means no sheet was shown: no credential.
    nonisolated static let noCredentialWindow: TimeInterval = 0.8

    private var running: [ObjectIdentifier: PasskeyCeremony] = [:]

    func register(userName: String, userHandle: Data) async throws -> PasskeyRegistration {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Relay.passkeyRelyingParty)
        let request = provider.createCredentialRegistrationRequest(challenge: Self.challenge(), name: userName, userID: userHandle)
        request.userVerificationPreference = .required
        // Platform passkeys are always discoverable (resident key required by construction);
        // the platform request has no residentKeyPreference property, only security keys do.
        request.prf = .checkForSupport
        let credential = try await run(request, preferImmediate: false)
        guard let registration = credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw PasskeyFailure.notAvailable
        }
        return PasskeyRegistration(credentialID: registration.credentialID, prfSupported: registration.prf?.isSupported ?? false)
    }

    func assert(credentialID: Data?, allowCrossDevice: Bool) async throws -> PasskeyAssertion {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Relay.passkeyRelyingParty)
        let request = provider.createCredentialAssertionRequest(challenge: Self.challenge())
        request.userVerificationPreference = .required
        request.allowedCredentials = credentialID.map { [ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)] } ?? []
        request.prf = .inputValues(.init(saltInput1: Relay.prfSaltUnlock, saltInput2: Relay.prfSaltBackup))
        // `preferImmediatelyAvailableCredentials` hides the cross-device route (QR, other phone).
        let credential = try await run(request, preferImmediate: !allowCrossDevice)
        guard let assertion = credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw PasskeyFailure.notAvailable
        }
        let prf = assertion.prf
        return PasskeyAssertion(
            credentialID: assertion.credentialID,
            prfFirst: prf.map { Self.bytes($0.first) },
            prfSecond: prf?.second.map { Self.bytes($0) }
        )
    }

    private func run(_ request: ASAuthorizationRequest, preferImmediate: Bool) async throws -> ASAuthorizationCredential {
        let ceremony = PasskeyCeremony(request: request, preferImmediate: preferImmediate)
        let key = ObjectIdentifier(ceremony)
        running[key] = ceremony
        defer { running[key] = nil }
        return try await ceremony.perform()
    }

    private static func challenge() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
    }

    private static func bytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    /// Maps an `ASAuthorizationError` to `PasskeyFailure`.
    /// On iOS 18+, an assertion run with `preferImmediatelyAvailableCredentials` and no matching
    /// credential fails with `.canceled` right away, without showing a sheet; a fast `.canceled` on
    /// such a request is therefore `.noCredential`. `.notInteractive` means the same.
    nonisolated static func failure(for error: Error, elapsed: TimeInterval, preferImmediate: Bool) -> PasskeyFailure {
        guard let error = error as? ASAuthorizationError else { return .notAvailable }
        switch error.code {
        case .canceled:
            return preferImmediate && elapsed < noCredentialWindow ? .noCredential : .cancelled
        case .notInteractive:
            return .noCredential
        default:
            return .notAvailable
        }
    }
}

/// One ASAuthorizationController run bridged to async/await.
private final class PasskeyCeremony: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let request: ASAuthorizationRequest
    private let preferImmediate: Bool
    private var continuation: CheckedContinuation<ASAuthorizationCredential, Error>?
    private var started = Date()

    init(request: ASAuthorizationRequest, preferImmediate: Bool) {
        self.request = request
        self.preferImmediate = preferImmediate
    }

    func perform() async throws -> ASAuthorizationCredential {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            started = Date()
            if preferImmediate {
                controller.performRequests(options: .preferImmediatelyAvailableCredentials)
            } else {
                controller.performRequests()
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization.credential)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let failure = PlatformPasskeyService.failure(for: error, elapsed: Date().timeIntervalSince(started), preferImmediate: preferImmediate)
        continuation?.resume(throwing: failure)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // A ceremony only starts from on-screen UI, so a window scene exists.
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            preconditionFailure("passkey ceremony without a window scene")
        }
        return scene.keyWindow ?? scene.windows.first ?? ASPresentationAnchor(windowScene: scene)
    }
}
