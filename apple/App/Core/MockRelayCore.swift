import CryptoKit
import Foundation

/// Stand-in for relay-core while RelayCoreFFI.xcframework is not linked. Same contract, classical
/// crypto only (X25519 + Ed25519 + AES-GCM from CryptoKit), its own wire format: two mock apps talk
/// to each other, never to the real core. Réglages shows which core runs.
nonisolated final class MockRelayCore: RelayCoreAPI {
    private var state: MockState
    private let signing: Curve25519.Signing.PrivateKey
    private let agreement: Curve25519.KeyAgreement.PrivateKey

    var implementationName: String { "Cœur de test (CryptoKit, sans post-quantique)" }

    private init(state: MockState) throws(RelayCoreError) {
        guard let s = try? Curve25519.Signing.PrivateKey(rawRepresentation: state.signing),
            let a = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.agreement)
        else { throw .malformed("état illisible") }
        self.state = state
        self.signing = s
        self.agreement = a
    }

    static func create(displayName: String) -> MockRelayCore {
        let state = MockState(
            name: displayName, signing: Curve25519.Signing.PrivateKey().rawRepresentation,
            agreement: Curve25519.KeyAgreement.PrivateKey().rawRepresentation, createdAt: Clock.nowMs)
        // Fresh keys always parse.
        return try! MockRelayCore(state: state)
    }

    static func restore(state: Data) throws(RelayCoreError) -> MockRelayCore {
        guard let decoded = try? JSONDecoder().decode(MockState.self, from: state) else {
            throw .malformed("état illisible")
        }
        return try MockRelayCore(state: decoded)
    }

    // MARK: Identity

    func exportState() -> Data { (try? JSONEncoder().encode(state)) ?? Data() }
    func fingerprintHex() -> String { Self.fingerprint(signing.publicKey.rawRepresentation) }
    func safetyWords() -> [String] { Self.words(Data(hex: fingerprintHex()) ?? Data()) }
    func mailboxHex() -> String { Self.mailbox(fingerprintHex()) }
    func displayName() -> String { state.name }
    func setDisplayName(_ name: String) { state.name = name }

    func myCard(nodeUrl: String?, handle: String?) -> String {
        var card = MockCard(
            name: state.name, sign: signing.publicKey.rawRepresentation, kx: agreement.publicKey.rawRepresentation,
            node: nodeUrl, handle: handle, created: state.createdAt, sig: Data())
        card.sig = (try? signing.signature(for: card.signedBytes)) ?? Data()
        return "relay1:" + ((try? JSONEncoder().encode(card)) ?? Data()).base64url
    }

    func myCompactLink(nodeUrl: String?) -> String {
        let compact = CompactJSON(fingerprint: fingerprintHex(), nodeUrl: nodeUrl, handle: state.handle)
        return "relay1c:" + Data(JSON.encode(compact).utf8).base64url
    }

    func deviceSigningPublic() -> Data { signing.publicKey.rawRepresentation }

    func signNodeChallenge(nonce: Data) -> Data {
        var message = Data("soma-relay/node-auth/v1".utf8)
        message.append(nonce)
        message.append(Data(hex: mailboxHex()) ?? Data())
        return (try? signing.signature(for: message)) ?? Data()
    }

    func rotatePrekeyIfDue(nowMs: Int64) -> Bool { false }

    // MARK: Contacts

    func addContact(card: String) throws(RelayCoreError) -> String { try add(card: card, replacing: false) }
    func addContactReplacing(card: String) throws(RelayCoreError) -> String { try add(card: card, replacing: true) }

    private func add(card text: String, replacing: Bool) throws(RelayCoreError) -> String {
        let card = try Self.parseCard(text)
        let fp = Self.fingerprint(card.sign)
        guard fp != fingerprintHex() else { throw .invalidCard("C'est ta propre carte.") }
        if let known = state.contacts[fp], known.kx != card.kx, !replacing {
            throw .keyChanged("La clé de \(known.name) a changé.")
        }
        let existing = state.contacts[fp]
        let contact = MockContact(
            name: existing?.name ?? card.name, sign: card.sign, kx: card.kx, node: card.node, handle: card.handle,
            verified: existing?.verified ?? false, addedAt: existing?.addedAt ?? Clock.nowMs)
        state.contacts[fp] = contact
        return JSON.encode(contact.json(fp))
    }

    func parseCompactLink(_ link: String) throws(RelayCoreError) -> String {
        guard link.hasPrefix("relay1c:"), let data = Data(base64url: String(link.dropFirst(8))),
            let text = String(data: data, encoding: .utf8), JSON.decode(CompactJSON.self, text) != nil
        else { throw .malformed("Lien illisible.") }
        return text
    }

    func contacts() -> String {
        JSON.encode(state.contacts.map { $0.value.json($0.key) }.sorted { $0.addedAt < $1.addedAt })
    }

    func removeContact(fp: String) { state.contacts[fp] = nil }
    func setVerified(fp: String, verified: Bool) { state.contacts[fp]?.verified = verified }
    func renameContact(fp: String, name: String) { state.contacts[fp]?.name = name }

    func contactSafetyWords(fp: String) -> [String] {
        Self.words(pairDigest(fp))
    }

    func contactSafetyCode(fp: String) -> String {
        let d = pairDigest(fp)
        let groups = (0..<3).map { i -> String in
            let v = (UInt32(d[i * 2]) << 8 | UInt32(d[i * 2 + 1])) % 1000
            return String(format: "%03d", v)
        }
        return groups.joined(separator: " ")
    }

    private func pairDigest(_ fp: String) -> Data {
        let pair = [fingerprintHex(), fp].sorted().joined()
        return Data(SHA256.hash(data: Data(("soma-relay/safety" + pair).utf8)))
    }

    // MARK: Messaging

    func encryptFor(fp: String, appMessageJson: String) throws(RelayCoreError) -> Data {
        guard let contact = state.contacts[fp] else { throw .noSession("Contact inconnu.") }
        let inner = MockInner(from: fingerprintHex(), card: myCard(nodeUrl: state.node, handle: state.handle), msg: appMessageJson)
        let key = try sharedKey(contact.kx, info: "msg")
        let sealed = try seal(inner, key: key)
        var body = agreement.publicKey.rawRepresentation
        body.append(sealed)
        return MockEnvelope(kind: 1, tag: Data(hex: Self.mailbox(fp)) ?? Data(count: 16), body: body).bytes
    }

    /// First messages to strangers: sealed to their X25519 key taken from a card.
    func encryptFirst(card: String, appMessageJson: String) throws(RelayCoreError) -> Data {
        _ = try addContact(card: card)
        return try encryptFor(fp: Self.fingerprint(try Self.parseCard(card).sign), appMessageJson: appMessageJson)
    }

    func meshTagFor(fp: String, nowMs: Int64) -> Data {
        guard let contact = state.contacts[fp], let key = try? sharedKey(contact.kx, info: "mesh") else { return Data(count: 16) }
        return meshTag(key: key, hour: nowMs / 3_600_000)
    }

    func retagForMesh(envelope: Data, fp: String, nowMs: Int64) -> Data {
        guard var env = MockEnvelope(bytes: envelope) else { return envelope }
        env.tag = meshTagFor(fp: fp, nowMs: nowMs)
        return env.bytes
    }

    func open(envelope: Data, nowMs: Int64) throws(RelayCoreError) -> String? {
        guard let env = MockEnvelope(bytes: envelope) else { throw .malformed("Enveloppe illisible.") }
        let envId = env.id.hex
        if state.seen.contains(envId) { return nil }
        switch env.kind {
        case 1:
            guard isMine(tag: env.tag, nowMs: nowMs), env.body.count > 32 else { return nil }
            let senderKX = env.body.prefix(32)
            guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderKX) else {
                throw .malformed("Clé illisible.")
            }
            let key = try derive(peer, info: "msg")
            let inner: MockInner = try open(env.body.dropFirst(32), key: key)
            remember(envId)
            if state.contacts[inner.from] == nil { _ = try? addContact(card: inner.card) }
            if let group = inner.group {
                state.groups[group.id] = group
                if inner.msg.isEmpty { return nil }
            }
            guard let message = AppMessage.decode(inner.msg) else { throw .malformed("Message illisible.") }
            return JSON.encode(InboundJSON(from: inner.from, group: nil, channel: nil, message: message, envelopeId: envId))
        case 2:
            guard let group = state.groups.values.first(where: { Self.groupTag($0.id) == env.tag }),
                let keyData = Data(base64url: group.key)
            else { return nil }
            let inner: MockInner = try open(env.body, key: SymmetricKey(data: keyData))
            remember(envId)
            guard inner.from != fingerprintHex(), let message = AppMessage.decode(inner.msg) else { return nil }
            return JSON.encode(InboundJSON(from: inner.from, group: group.id, channel: nil, message: message, envelopeId: envId))
        case 3:
            guard let channel = state.channels.first(where: { Self.channelTag($0.key) == env.tag }) else { return nil }
            let inner: MockInner = try open(env.body, key: Self.channelKey(channel.key, password: channel.value))
            remember(envId)
            guard inner.from != fingerprintHex(), let message = AppMessage.decode(inner.msg) else { return nil }
            return JSON.encode(InboundJSON(from: inner.from, group: nil, channel: channel.key, message: message, envelopeId: envId))
        default:
            return nil
        }
    }

    private func remember(_ id: String) {
        state.seen.append(id)
        if state.seen.count > 4096 { state.seen.removeFirst(state.seen.count - 4096) }
    }

    private func isMine(tag: Data, nowMs: Int64) -> Bool {
        if tag == Data(hex: mailboxHex()) { return true }
        let hour = nowMs / 3_600_000
        for contact in state.contacts.values {
            guard let key = try? sharedKey(contact.kx, info: "mesh") else { continue }
            if meshTag(key: key, hour: hour) == tag || meshTag(key: key, hour: hour - 1) == tag { return true }
        }
        return false
    }

    // MARK: Groups

    func createGroup(name: String, memberFps: [String]) throws(RelayCoreError) -> String {
        for fp in memberFps where state.contacts[fp] == nil { throw .group("Membre inconnu.") }
        let id = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).hex
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64url
        state.groups[id] = MockGroup(id: id, name: name, members: memberFps + [fingerprintHex()], admins: [fingerprintHex()], key: key, distributed: [])
        return id
    }

    func groupEncrypt(groupId: String, appMessageJson: String) throws(RelayCoreError) -> [Data] {
        guard var group = state.groups[groupId], let keyData = Data(base64url: group.key) else { throw .group("Groupe inconnu.") }
        var out: [Data] = []
        for member in group.members where member != fingerprintHex() && !group.distributed.contains(member) {
            out.append(try distribution(group, to: member))
            group.distributed.append(member)
        }
        state.groups[groupId] = group
        let inner = MockInner(from: fingerprintHex(), card: "", msg: appMessageJson)
        // Same order as relay-core: distribution envelopes first, group envelope last.
        out.append(MockEnvelope(kind: 2, tag: Self.groupTag(groupId), body: try seal(inner, key: SymmetricKey(data: keyData))).bytes)
        return out
    }

    private func distribution(_ group: MockGroup, to fp: String) throws(RelayCoreError) -> Data {
        guard let contact = state.contacts[fp] else { throw .group("Membre inconnu.") }
        var shared = group
        shared.distributed = []
        let inner = MockInner(from: fingerprintHex(), card: myCard(nodeUrl: state.node, handle: state.handle), msg: "", group: shared)
        var body = agreement.publicKey.rawRepresentation
        body.append(try seal(inner, key: try sharedKey(contact.kx, info: "msg")))
        return MockEnvelope(kind: 1, tag: Data(hex: Self.mailbox(fp)) ?? Data(count: 16), body: body).bytes
    }

    func groups() -> String {
        JSON.encode(state.groups.values.map { GroupJSON(id: $0.id, name: $0.name, members: $0.members, admins: $0.admins, mailboxes: $0.members.map(Self.mailbox)) }.sorted { $0.name < $1.name })
    }

    func groupAdd(groupId: String, fp: String) throws(RelayCoreError) -> [Data] {
        guard var group = state.groups[groupId] else { throw .group("Groupe inconnu.") }
        if !group.members.contains(fp) { group.members.append(fp) }
        state.groups[groupId] = group
        return [try distribution(group, to: fp)]
    }

    func groupRemove(groupId: String, fp: String) throws(RelayCoreError) -> [Data] {
        guard var group = state.groups[groupId] else { throw .group("Groupe inconnu.") }
        group.members.removeAll { $0 == fp }
        group.key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64url
        group.distributed = []
        state.groups[groupId] = group
        return try group.members.filter { $0 != fingerprintHex() }.map { m throws(RelayCoreError) in try distribution(group, to: m) }
    }

    func leaveGroup(groupId: String) { state.groups[groupId] = nil }

    // MARK: Channels

    func channelEncrypt(name: String, password: String?, appMessageJson: String) -> Data {
        let inner = MockInner(from: fingerprintHex(), card: "", msg: appMessageJson)
        let body = (try? seal(inner, key: Self.channelKey(name, password: password))) ?? Data()
        return MockEnvelope(kind: 3, tag: Self.channelTag(name), body: body).bytes
    }

    func joinChannel(name: String, password: String?) { state.channels[name] = password }
    func leaveChannel(name: String) { state.channels[name] = nil }

    // MARK: Attachments

    func sealAttachment(_ plain: Data) -> Data {
        let key = SymmetricKey(size: .bits256)
        let sha = Data(SHA256.hash(data: plain))
        let box = try? AES.GCM.seal(plain, using: key, authenticating: sha)
        var out = key.withUnsafeBytes { Data($0) }
        out.append(sha)
        out.append(box?.combined ?? Data())
        return out
    }

    func openAttachment(key: Data, sha256: Data, ciphertext: Data) throws(RelayCoreError) -> Data {
        guard let box = try? AES.GCM.SealedBox(combined: ciphertext),
            let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: sha256),
            Data(SHA256.hash(data: plain)) == sha256
        else { throw .decrypt("Pièce jointe illisible.") }
        return plain
    }

    // MARK: Calls

    func callKey(fp: String, callId: String) throws(RelayCoreError) -> Data {
        guard let contact = state.contacts[fp] else { throw .noSession("Contact inconnu.") }
        return try sharedKey(contact.kx, info: "call/" + callId).withUnsafeBytes { Data($0) }
    }

    func makeMeshRouter() -> MeshRouterAPI { SwiftMeshRouter() }

    func envelopeTagHex(_ envelope: Data) -> String? { MockEnvelope(bytes: envelope)?.tag.hex }
    func envelopeKind(_ envelope: Data) -> String? {
        switch MockEnvelope(bytes: envelope)?.kind {
        case 1: "direct"
        case 2: "group"
        case 3: "channel"
        case nil: nil
        default: "control"
        }
    }

    func signDirectoryEntry(handle: String) throws(RelayCoreError) -> (card: String, sig: Data) {
        let card = myCard(nodeUrl: state.node, handle: handle)
        var message = Data("soma-relay/directory/v1".utf8)
        message.append(UInt8(handle.utf8.count))
        message.append(Data(handle.utf8))
        message.append(Data(card.utf8))
        guard let sig = try? signing.signature(for: message) else { throw .unknown("Signature impossible.") }
        return (card, sig)
    }

    /// Handle published on the node, carried in the compact link.
    func setHandle(_ handle: String?, node: String?) {
        state.handle = handle
        state.node = node
    }

    // MARK: Crypto helpers

    private func sharedKey(_ kx: Data, info: String) throws(RelayCoreError) -> SymmetricKey {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: kx) else { throw .malformed("Clé illisible.") }
        return try derive(peer, info: info)
    }

    private func derive(_ peer: Curve25519.KeyAgreement.PublicKey, info: String) throws(RelayCoreError) -> SymmetricKey {
        guard let secret = try? agreement.sharedSecretFromKeyAgreement(with: peer) else { throw .decrypt("Accord de clé impossible.") }
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data("soma-relay/mock".utf8), sharedInfo: Data(info.utf8), outputByteCount: 32)
    }

    private func meshTag(key: SymmetricKey, hour: Int64) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("mesh-tag\(hour)".utf8), using: key)).prefix(16)
    }

    private func seal<T: Encodable>(_ value: T, key: SymmetricKey) throws(RelayCoreError) -> Data {
        guard let plain = try? JSONEncoder().encode(value), let box = try? AES.GCM.seal(Self.pad(plain), using: key),
            let combined = box.combined
        else { throw .unknown("Chiffrement impossible.") }
        return combined
    }

    private func open<T: Decodable>(_ data: Data, key: SymmetricKey) throws(RelayCoreError) -> T {
        guard let box = try? AES.GCM.SealedBox(combined: data), let padded = try? AES.GCM.open(box, using: key),
            let value = try? JSONDecoder().decode(T.self, from: Self.unpad(padded))
        else { throw .decrypt("Déchiffrement impossible.") }
        return value
    }

    /// Length prefix then zeros to 256 B / 1 KiB / 4 KiB / 16 KiB / 64 KiB / n * 64 KiB.
    static func pad(_ data: Data) -> Data {
        let need = data.count + 4
        let size = [256, 1024, 4096, 16384, 65536].first { $0 >= need } ?? ((need + 65535) / 65536) * 65536
        var out = Data()
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(data)
        out.append(Data(count: size - out.count))
        return out
    }

    static func unpad(_ data: Data) -> Data {
        guard data.count >= 4 else { return Data() }
        let length = Int(data.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
        return data.dropFirst(4).prefix(length)
    }

    static func fingerprint(_ signPub: Data) -> String {
        var input = Data("soma-relay/mock-fp".utf8)
        input.append(signPub)
        return Data(SHA256.hash(data: input)).hex
    }

    static func mailbox(_ fp: String) -> String {
        var input = Data("soma-relay/mailbox".utf8)
        input.append(Data(hex: fp) ?? Data())
        return Data(SHA256.hash(data: input)).prefix(16).hex
    }

    static func groupTag(_ id: String) -> Data { Data(SHA256.hash(data: Data(("group" + id).utf8))).prefix(16) }
    static func channelTag(_ name: String) -> Data { Data(SHA256.hash(data: Data(("channel" + name.lowercased()).utf8))).prefix(16) }
    static func channelKey(_ name: String, password: String?) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data(("channel-key" + name.lowercased() + (password ?? "")).utf8)))
    }

    static func parseCard(_ text: String) throws(RelayCoreError) -> MockCard {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("relay1:"), let data = Data(base64url: String(trimmed.dropFirst(7))),
            let card = try? JSONDecoder().decode(MockCard.self, from: data)
        else { throw .invalidCard("Carte illisible.") }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: card.sign),
            key.isValidSignature(card.sig, for: card.signedBytes)
        else { throw .invalidCard("Signature de la carte invalide.") }
        return card
    }

    static func words(_ digest: Data) -> [String] {
        let bytes = Array(digest)
        guard bytes.count >= 8 else { return [] }
        return (0..<4).map { i in
            let index = (Int(bytes[i * 2]) << 8 | Int(bytes[i * 2 + 1])) % SafetyWordList.words.count
            return SafetyWordList.words[index]
        }
    }
}

// MARK: - Mock state and wire structs

nonisolated struct MockState: Codable {
    var name: String
    var signing: Data
    var agreement: Data
    var createdAt: Int64
    var node: String?
    var handle: String?
    var contacts: [String: MockContact] = [:]
    var groups: [String: MockGroup] = [:]
    var channels: [String: String?] = [:]
    var seen: [String] = []
}

nonisolated struct MockContact: Codable {
    var name: String
    var sign: Data
    var kx: Data
    var node: String?
    var handle: String?
    var verified: Bool
    var addedAt: Int64

    func json(_ fp: String) -> ContactJSON {
        ContactJSON(fingerprint: fp, name: name, mailbox: MockRelayCore.mailbox(fp), verified: verified, nodeUrl: node, handle: handle, addedAt: addedAt)
    }
}

nonisolated struct MockGroup: Codable {
    var id: String
    var name: String
    var members: [String]
    var admins: [String]
    var key: String
    var distributed: [String]
}

nonisolated struct MockCard: Codable {
    var name: String
    var sign: Data
    var kx: Data
    var node: String?
    var handle: String?
    var created: Int64
    var sig: Data

    var signedBytes: Data {
        var d = Data(name.utf8)
        d.append(sign)
        d.append(kx)
        d.append(Data((node ?? "").utf8))
        d.append(Data((handle ?? "").utf8))
        d.append(Data(String(created).utf8))
        return d
    }
}

nonisolated struct MockInner: Codable {
    var from: String
    var card: String
    var msg: String
    var group: MockGroup?
}

/// `S R` magic, kind, tag (16), ttl, id (16), body.
nonisolated struct MockEnvelope {
    var kind: UInt8
    var tag: Data
    var ttl: UInt8 = 7
    var id: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    var body: Data

    init(kind: UInt8, tag: Data, body: Data) {
        self.kind = kind
        self.tag = tag
        self.body = body
    }

    init?(bytes: Data) {
        let b = Data(bytes)
        guard b.count >= 36, b[0] == 0x53, b[1] == 0x52 else { return nil }
        kind = b[2]
        tag = b.subdata(in: 3..<19)
        ttl = b[19]
        id = b.subdata(in: 20..<36)
        body = b.subdata(in: 36..<b.count)
    }

    var bytes: Data {
        var d = Data([0x53, 0x52, kind])
        d.append(tag.prefix(16))
        d.append(ttl)
        d.append(id)
        d.append(body)
        return d
    }
}
