#if canImport(RelayCore)
import Foundation
import RelayCore

/// relay-core through UniFFI (RelayCoreFFI.xcframework + the generated `RelayCore` module).
nonisolated final class FFIRelayCore: RelayCoreAPI {
    private let engine: RelayEngine

    var implementationName: String { "relay-core (Rust, hybride post-quantique)" }

    private init(_ engine: RelayEngine) { self.engine = engine }

    static func create(displayName: String) -> FFIRelayCore {
        FFIRelayCore(RelayEngine.create(displayName: displayName))
    }

    static func restore(state: Data) throws(RelayCoreError) -> FFIRelayCore {
        do { return FFIRelayCore(try RelayEngine.restore(state: state)) } catch { throw Self.map(error) }
    }

    /// The generated `RelayError` is internal to the RelayCore module: read its case from its
    /// reflection (`RelayCore.RelayError.KeyChanged(message: "...")`).
    static func map(_ error: Error) -> RelayCoreError {
        let text = String(reflecting: error)
        var message = text
        if let start = text.range(of: "message: \""), let end = text.range(of: "\")", options: .backwards), start.upperBound <= end.lowerBound {
            message = String(text[start.upperBound..<end.lowerBound])
        }
        if text.contains("InvalidCard") { return .invalidCard(message) }
        if text.contains("KeyChanged") { return .keyChanged(message) }
        if text.contains("NoSession") { return .noSession(message) }
        if text.contains("Decrypt") { return .decrypt(message) }
        if text.contains("Malformed") { return .malformed(message) }
        if text.contains("Storage") { return .storage(message) }
        if text.contains("Group") { return .group(message) }
        return .unknown(message)
    }

    private func run<T>(_ body: () throws -> T) throws(RelayCoreError) -> T {
        do { return try body() } catch { throw Self.map(error) }
    }

    // Identity
    func exportState() -> Data { engine.exportState() }
    func fingerprintHex() -> String { engine.fingerprintHex() }
    func safetyWords() -> [String] { engine.safetyWords() }
    func mailboxHex() -> String { engine.mailboxHex() }
    func displayName() -> String { engine.displayName() }
    func setDisplayName(_ name: String) { engine.setDisplayName(name: name) }
    func myCard(nodeUrl: String?, handle: String?) -> String { engine.myCard(nodeUrl: nodeUrl, handle: handle) }
    func myCompactLink(nodeUrl: String?) -> String { engine.myCompactLink(nodeUrl: nodeUrl) }
    func deviceSigningPublic() -> Data { engine.deviceSigningPublic() }
    func signNodeChallenge(nonce: Data) -> Data { engine.signNodeChallenge(nonce: nonce) }
    func rotatePrekeyIfDue(nowMs: Int64) -> Bool { engine.rotatePrekeyIfDue(nowMs: nowMs) }

    // Contacts
    func addContact(card: String) throws(RelayCoreError) -> String { try run { try engine.addContact(card: card) } }
    func addContactReplacing(card: String) throws(RelayCoreError) -> String { try run { try engine.addContactReplacing(card: card) } }
    func parseCompactLink(_ link: String) throws(RelayCoreError) -> String { try run { try engine.parseCompactLink(link: link) } }
    func contacts() -> String { engine.contacts() }
    func removeContact(fp: String) { engine.removeContact(fp: fp) }
    func setVerified(fp: String, verified: Bool) { engine.setVerified(fp: fp, verified: verified) }
    func renameContact(fp: String, name: String) { engine.renameContact(fp: fp, name: name) }
    func contactSafetyWords(fp: String) -> [String] { engine.contactSafetyWords(fp: fp) }
    func contactSafetyCode(fp: String) -> String { engine.contactSafetyCode(fp: fp) }

    // Messaging
    func encryptFor(fp: String, appMessageJson: String) throws(RelayCoreError) -> Data {
        try run { try engine.encryptFor(fp: fp, appMessageJson: appMessageJson) }
    }
    func meshTagFor(fp: String, nowMs: Int64) -> Data { engine.meshTagFor(fp: fp, nowMs: nowMs) }
    func retagForMesh(envelope: Data, fp: String, nowMs: Int64) -> Data { engine.retagForMesh(envelope: envelope, fp: fp, nowMs: nowMs) }
    func open(envelope: Data, nowMs: Int64) throws(RelayCoreError) -> String? { try run { try engine.open(envelope: envelope, nowMs: nowMs) } }

    // Groups
    func createGroup(name: String, memberFps: [String]) throws(RelayCoreError) -> String {
        try run { try engine.createGroup(name: name, memberFps: memberFps) }
    }
    func groupEncrypt(groupId: String, appMessageJson: String) throws(RelayCoreError) -> [Data] {
        try run { try engine.groupEncrypt(groupId: groupId, appMessageJson: appMessageJson) }
    }
    func groups() -> String { engine.groups() }
    func groupAdd(groupId: String, fp: String) throws(RelayCoreError) -> [Data] { try run { try engine.groupAdd(groupId: groupId, fp: fp) } }
    func groupRemove(groupId: String, fp: String) throws(RelayCoreError) -> [Data] { try run { try engine.groupRemove(groupId: groupId, fp: fp) } }
    func leaveGroup(groupId: String) { engine.leaveGroup(groupId: groupId) }

    // Channels
    func channelEncrypt(name: String, password: String?, appMessageJson: String) -> Data {
        (try? engine.channelEncrypt(name: name, password: password, appMessageJson: appMessageJson)) ?? Data()
    }
    func joinChannel(name: String, password: String?) { try? engine.joinChannel(name: name, password: password) }
    func leaveChannel(name: String) { engine.leaveChannel(name: name) }

    // Attachments
    func sealAttachment(_ plain: Data) -> Data { engine.sealAttachment(plain: plain) }
    func openAttachment(key: Data, sha256: Data, ciphertext: Data) throws(RelayCoreError) -> Data {
        try run { try engine.openAttachment(key: key, sha256: sha256, ciphertext: ciphertext) }
    }

    // Calls
    func callKey(fp: String, callId: String) throws(RelayCoreError) -> Data { try run { try engine.callKey(fp: fp, callId: callId) } }

    // Client helpers
    func envelopeTagHex(_ envelope: Data) -> String? {
        guard let json = try? engine.envelopeInfo(envelope: envelope),
            let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return nil }
        return obj["tag"] as? String
    }

    /// The core does not expose a detached Ed25519 signature yet (node directory PUT).
    func signDetached(_ data: Data) -> Data? { nil }

    func makeMeshRouter() -> MeshRouterAPI { FFIMeshRouter() }
}

nonisolated final class FFIMeshRouter: MeshRouterAPI {
    private let router = MeshRouter()

    func onFrame(_ frame: Data, fromLink: UInt32, nowMs: Int64) -> MeshResult {
        let r = router.onFrame(frame: frame, fromLink: fromLink, nowMs: nowMs)
        // Frame = ver(1) || hops_left(1) || ...; envelopes start with ttl 7.
        let hops = frame.count > 1 ? max(1, 8 - Int(frame[frame.startIndex + 1])) : nil
        return MeshResult(complete: r.complete, forward: r.forward, excludeLink: r.excludeLink, hops: hops)
    }

    func framesFor(envelope: Data, mtu: UInt32) -> [Data] { router.framesFor(envelope: envelope, mtu: mtu) }
}
#endif
