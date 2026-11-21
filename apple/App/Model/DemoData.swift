import Foundation

/// `-RelayDemoData YES`: the conversation of the design artboards (Inès over the mesh, 2 hops,
/// a voice note, a message still on its way), in an in-memory database. `-RelayDemoScreen`
/// opens a screen directly: conversations, chat, qr, call, contacts, settings, onboarding.
enum DemoData {
    static let ines = "4f2a91c077de3b5e8a10c2d4f6a8b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f607"
    static let malik = "9b31e0c5aa7d4e21f0b6c3d8e9a1b2c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f901"
    static let lou = "c07e55d1b2a3948576a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d902"
    static let nadia = "e11a7f3c9d2b4a5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6"
    static let callWords = ["lanterne", "orage", "cobalt", "mesure"]

    static var screen: String? { AppConfig.demoAllowed ? UserDefaults.standard.string(forKey: "RelayDemoScreen") : nil }

    static func seed(_ model: AppModel) {
        model.adoptCore(MockRelayCore.create(displayName: "Quentin"))
        model.handle = "quentin"
        let now = Clock.nowMs
        model.contacts = [
            ContactJSON(fingerprint: ines, name: "Inès", mailbox: "a1", verified: true, nodeUrl: AppModel.defaultNodeURL, handle: "ines", addedAt: now - 86_400_000 * 30),
            ContactJSON(fingerprint: malik, name: "Malik", mailbox: "a2", verified: true, nodeUrl: AppModel.defaultNodeURL, handle: "malik", addedAt: now - 86_400_000 * 20),
            ContactJSON(fingerprint: lou, name: "Lou", mailbox: "a3", verified: false, nodeUrl: nil, handle: nil, addedAt: now - 86_400_000 * 2),
            ContactJSON(fingerprint: nadia, name: "Nadia", mailbox: "a4", verified: true, nodeUrl: AppModel.defaultNodeURL, handle: "nadia", addedAt: now - 86_400_000 * 9),
        ]
        model.groups = [GroupJSON(id: "stand", name: "Équipe stand 4", members: [ines, malik, lou], admins: [ines])]
        model.channels = ["festival"]
        model.meshPeerCount = 5
        model.nearby = [
            NearbyPeer(id: "K7QX", code: "K7", name: nil, compactLink: nil, connected: true),
            NearbyPeer(id: "M2AB", code: "M2", name: "Sami", compactLink: nil, connected: true),
            NearbyPeer(id: "R9CD", code: "R9", name: nil, compactLink: nil, connected: true),
            NearbyPeer(id: "T4EF", code: "T4", name: "Jade", compactLink: nil, connected: true),
            NearbyPeer(id: "W8GH", code: "W8", name: nil, compactLink: nil, connected: false),
        ]
        model.routes[ines] = PathInfo(transport: .mesh, hops: 2, via: "K7", at: Date())
        model.nodeState = .ready

        let calendar = Calendar.current
        let base = calendar.date(bySettingHour: 10, minute: 42, second: 0, of: Date()) ?? Date()
        func ms(_ minutes: Double) -> Int64 { Int64((base.timeIntervalSince1970 + minutes * 60) * 1000) }

        let direct = AppModel.directId(ines)
        conversation(model, id: direct, kind: .direct, title: "Inès", peer: ines, at: ms(4), unread: 0, transport: .mesh, preview: "J'arrive. On s'appelle dès que t'as la 4G.")
        message(model, direct, from: ines, at: ms(0), text: "T'es où ? Plus aucun réseau ici.", status: .read, transport: .node, hops: nil)
        message(model, direct, from: nil, at: ms(1), text: "Stand 4. Je te vois sur le mesh, deux téléphones entre nous.", status: .read, transport: .mesh, hops: 2)
        message(model, direct, from: nil, at: ms(1.5), text: "Je t'envoie le plan par Internet si ça passe.", status: .delivered, transport: .node, hops: nil)
        var voice = AppMessage(id: UUIDv7.make(ms: ms(2)), ts: ms(2), kind: .audio)
        voice.attachment = .init(
            mime: "audio/mp4", size: 36_000, sha256: "", key: "", durationMs: 9_000,
            levels: (0..<48).map { i in Float(0.25 + 0.6 * abs(sin(Double(i) * 0.55)) * (i % 7 == 0 ? 0.5 : 1)) })
        save(model, voice, conversation: direct, from: ines, status: .delivered, transport: .mesh, hops: 2)
        message(model, direct, from: nil, at: ms(4), text: "J'arrive. On s'appelle dès que t'as la 4G.", status: .sent, transport: .mesh, hops: nil, relays: 3)

        let group = AppModel.groupId("stand")
        conversation(model, id: group, kind: .group, title: "Équipe stand 4", peer: "stand", at: ms(-6), unread: 3, transport: .mesh, preview: "Malik : Le groupe électrogène repart à midi")
        message(model, group, from: malik, at: ms(-6), text: "Le groupe électrogène repart à midi", status: .delivered, transport: .mesh, hops: 3)

        let channel = AppModel.channelId("festival")
        conversation(model, id: channel, kind: .channel, title: "#festival", peer: "festival", at: ms(-18), unread: 0, transport: .mesh, preview: "Point d'eau ouvert derrière la grande scène")
        message(model, channel, from: lou, at: ms(-18), text: "Point d'eau ouvert derrière la grande scène", status: .delivered, transport: .mesh, hops: 4)

        let m = AppModel.directId(malik)
        conversation(model, id: m, kind: .direct, title: "Malik", peer: malik, at: ms(-55), unread: 1, transport: .node, preview: "Je passe le chargeur solaire ce soir")
        message(model, m, from: malik, at: ms(-55), text: "Je passe le chargeur solaire ce soir", status: .delivered, transport: .node, hops: nil)

        let n = AppModel.directId(nadia)
        conversation(model, id: n, kind: .direct, title: "Nadia", peer: nadia, at: ms(-60 * 20), unread: 0, transport: .sms, preview: "Reçu par SMS chiffré, merci !")
        message(model, n, from: nadia, at: ms(-60 * 20), text: "Reçu par SMS chiffré, merci !", status: .delivered, transport: .sms, hops: nil)

        model.reloadConversations()
    }

    private static func conversation(
        _ model: AppModel, id: String, kind: ConversationKind, title: String, peer: String, at: Int64, unread: Int, transport: Transport, preview: String
    ) {
        model.db.save(ConversationRecord(id: id, kind: kind, title: title, peer: peer, lastAt: at, unread: unread, lastTransport: transport, previewSealed: SecretBox.shared.seal(preview)))
    }

    private static func message(
        _ model: AppModel, _ conversation: String, from: String?, at: Int64, text: String, status: DeliveryStatus, transport: Transport, hops: Int?, relays: Int? = nil
    ) {
        let m = AppMessage(id: UUIDv7.make(ms: at), ts: at, kind: .text, text: text)
        save(model, m, conversation: conversation, from: from, status: status, transport: transport, hops: hops, relays: relays)
    }

    private static func save(
        _ model: AppModel, _ m: AppMessage, conversation: String, from: String?, status: DeliveryStatus, transport: Transport, hops: Int?, relays: Int? = nil
    ) {
        model.db.save(MessageRecord(
            id: m.id, conversationId: conversation, sender: from, ts: m.ts, kind: m.kind.rawValue, bodySealed: SecretBox.shared.seal(m.json()),
            status: status, transport: transport, hops: hops, relays: relays, replyTo: nil, mediaPath: nil))
    }
}
