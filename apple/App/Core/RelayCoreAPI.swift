import Foundation

// The surface of relay-core as the app sees it (docs/specs/core-api.md). Two implementations:
// `FFIRelayCore` (the Rust core through UniFFI, when RelayCoreFFI.xcframework is linked) and
// `MockRelayCore` (CryptoKit stand-in, classical crypto only, for the simulator and the UI).
// Method names follow the spec in camelCase. JSON strings carry the spec's structs.

nonisolated enum RelayCoreError: Error, Equatable, Sendable {
    case invalidCard(String)
    case keyChanged(String)
    case noSession(String)
    case decrypt(String)
    case malformed(String)
    case unknown(String)
    case storage(String)
    case group(String)

    var message: String {
        switch self {
        case .invalidCard(let m), .keyChanged(let m), .noSession(let m), .decrypt(let m),
            .malformed(let m), .unknown(let m), .storage(let m), .group(let m):
            m
        }
    }
}

/// Result of feeding one mesh frame to the router.
nonisolated struct MeshResult: Sendable {
    /// A whole envelope, reassembled and seen for the first time.
    var complete: Data?
    /// Frames to send on, to every link but `excludeLink`.
    var forward: [Data]
    var excludeLink: UInt32
    /// Hops the frame travelled to reach us (1 = direct neighbour), when the router knows it.
    var hops: Int?
}

/// The sans-IO mesh router (fragmentation, dedup, TTL).
nonisolated protocol MeshRouterAPI: AnyObject {
    func onFrame(_ frame: Data, fromLink: UInt32, nowMs: Int64) -> MeshResult
    func framesFor(envelope: Data, mtu: UInt32) -> [Data]
}

/// One identity and everything it knows (contacts, sessions, groups, channels).
nonisolated protocol RelayCoreAPI: AnyObject {
    // Identity
    func exportState() -> Data
    func fingerprintHex() -> String
    func safetyWords() -> [String]
    func mailboxHex() -> String
    func displayName() -> String
    func setDisplayName(_ name: String)
    func myCard(nodeUrl: String?, handle: String?) -> String
    func myCompactLink(nodeUrl: String?) -> String
    func deviceSigningPublic() -> Data
    func signNodeChallenge(nonce: Data) -> Data
    @discardableResult func rotatePrekeyIfDue(nowMs: Int64) -> Bool

    // Contacts
    func addContact(card: String) throws(RelayCoreError) -> String
    func addContactReplacing(card: String) throws(RelayCoreError) -> String
    func parseCompactLink(_ link: String) throws(RelayCoreError) -> String
    func contacts() -> String
    func removeContact(fp: String)
    func setVerified(fp: String, verified: Bool)
    func renameContact(fp: String, name: String)
    func contactSafetyWords(fp: String) -> [String]
    func contactSafetyCode(fp: String) -> String

    // Messaging
    func encryptFor(fp: String, appMessageJson: String) throws(RelayCoreError) -> Data
    func meshTagFor(fp: String, nowMs: Int64) -> Data
    func retagForMesh(envelope: Data, fp: String, nowMs: Int64) -> Data
    func open(envelope: Data, nowMs: Int64) throws(RelayCoreError) -> String?

    // Groups
    func createGroup(name: String, memberFps: [String]) throws(RelayCoreError) -> String
    func groupEncrypt(groupId: String, appMessageJson: String) throws(RelayCoreError) -> [Data]
    func groups() -> String
    func groupAdd(groupId: String, fp: String) throws(RelayCoreError) -> [Data]
    func groupRemove(groupId: String, fp: String) throws(RelayCoreError) -> [Data]
    func leaveGroup(groupId: String)

    // Local channels
    func channelEncrypt(name: String, password: String?, appMessageJson: String) -> Data
    func joinChannel(name: String, password: String?)
    func leaveChannel(name: String)

    // Attachments: output = key(32) || sha256(32) || ciphertext
    func sealAttachment(_ plain: Data) -> Data
    func openAttachment(key: Data, sha256: Data, ciphertext: Data) throws(RelayCoreError) -> Data

    // Calls
    func callKey(fp: String, callId: String) throws(RelayCoreError) -> Data

    // Client helpers outside core-api.md (the adapter knows the wire layout).

    /// Hex routing tag of an envelope (mailbox for direct envelopes).
    func envelopeTagHex(_ envelope: Data) -> String?
    /// `direct`, `group`, `channel`, `announce` or `control`.
    func envelopeKind(_ envelope: Data) -> String?
    /// Ed25519 signature by the device key over arbitrary bytes (node directory PUT), nil when the
    /// core does not expose it.
    /// Own card carrying `handle` (node URL as last given to `myCard`) and the Ed25519 identity
    /// signature over "soma-relay/directory/v1" || u8 len(handle) || handle || card, for
    /// `PUT /v1/directory/{handle}`.
    func signDirectoryEntry(handle: String) throws(RelayCoreError) -> (card: String, sig: Data)

    /// Ed25519 signature by the device key (the one bound to the mailbox on the node) over
    /// "relay-vault-v1" || id || SHA-256(blob), for `PUT /v1/vault/{id}`. Nil without the Rust core.
    func signVault(id: String, blob: Data) -> Data?

    /// A fresh mesh router (one per app run).
    func makeMeshRouter() -> MeshRouterAPI

    /// Human name of the implementation, shown in Réglages.
    var implementationName: String { get }
}

/// Builds engines: the real core when it is linked, the mock otherwise.
enum RelayCoreFactory {
    static var usesRealCore: Bool {
        #if canImport(RelayCore)
        true
        #else
        false
        #endif
    }

    static func create(displayName: String) -> RelayCoreAPI {
        #if canImport(RelayCore)
        FFIRelayCore.create(displayName: displayName)
        #else
        MockRelayCore.create(displayName: displayName)
        #endif
    }

    static func restore(state: Data) throws(RelayCoreError) -> RelayCoreAPI {
        #if canImport(RelayCore)
        try FFIRelayCore.restore(state: state)
        #else
        try MockRelayCore.restore(state: state)
        #endif
    }

    // MARK: .relaykey export

    /// Shortest passphrase accepted for a new export (`EXPORT_MIN_PASSPHRASE` in relay-core).
    static let exportMinPassphrase = 10

    /// `relaystate2:` text of `state`, sealed with `passphrase` (Argon2id 64 MiB, then AES-256-GCM).
    /// Slow on purpose (about a second): call it off the main actor. Nil without the Rust core.
    nonisolated static func sealExport(passphrase: String, state: Data) -> String? {
        #if canImport(RelayCore)
        FFIRelayCore.sealExport(passphrase: passphrase, state: state)
        #else
        nil
        #endif
    }

    /// Engine state from a `.relaykey` text: `relaystate1:` needs no passphrase, `relaystate2:` does.
    nonisolated static func openExport(passphrase: String?, text: String) throws(ExportError) -> Data {
        #if canImport(RelayCore)
        try FFIRelayCore.openExport(passphrase: passphrase, text: text)
        #else
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(ExportError.v2Prefix) { throw .unavailable }
        guard trimmed.hasPrefix(ExportError.v1Prefix),
            let state = Data(base64url: String(trimmed.dropFirst(ExportError.v1Prefix.count)))
        else { throw .unreadable }
        return state
        #endif
    }
}

/// Why a `.relaykey` text does not open.
nonisolated enum ExportError: Error, Equatable, Sendable {
    /// `relaystate2:` with no passphrase, or a wrong one.
    case passphrase
    /// Not a `.relaykey` text, or damaged.
    case unreadable
    /// The test core cannot open a sealed export.
    case unavailable

    static let v1Prefix = "relaystate1:"
    static let v2Prefix = "relaystate2:"

    /// True when `text` is a sealed export, which needs the passphrase field.
    static func needsPassphrase(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(v2Prefix)
    }

    var message: String {
        switch self {
        case .passphrase: "Phrase de passe incorrecte."
        case .unreadable: "Ce fichier n'est pas une identité Soma Relay."
        case .unavailable: "Cette version de test ne sait pas ouvrir un export chiffré."
        }
    }
}
