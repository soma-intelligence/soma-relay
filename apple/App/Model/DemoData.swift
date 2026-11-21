import CoreLocation
import Foundation
import UIKit

/// `-RelayDemoData YES`: the conversation of the design artboards (Inès over the mesh, 2 hops,
/// a voice note, a message still on its way), in an in-memory database. `-RelayDemoScreen`
/// opens a screen directly: conversations, chat, qr, call, contacts, settings, onboarding;
/// v1.1: group (poll, live location, reactions, reply), files (PDF, link preview, edit),
/// attach, poll-new, location, document, map, search, list-search, reactions, edit.
enum DemoData {
    static let ines = "4f2a91c077de3b5e8a10c2d4f6a8b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f607"
    static let malik = "9b31e0c5aa7d4e21f0b6c3d8e9a1b2c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f901"
    static let lou = "c07e55d1b2a3948576a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d902"
    static let nadia = "e11a7f3c9d2b4a5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6"
    static let callWords = ["lanterne", "orage", "cobalt", "mesure"]
    /// Parc de la Villette, where the demo festival happens.
    static let here = CLLocationCoordinate2D(latitude: 48.89386, longitude: 2.39102)

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
        react(model, voice.id, ["": "❤️"])
        message(model, direct, from: nil, at: ms(4), text: "J'arrive. On s'appelle dès que t'as la 4G.", status: .sent, transport: .mesh, hops: nil, relays: 3)

        let group = AppModel.groupId("stand")
        conversation(model, id: group, kind: .group, title: "Équipe stand 4", peer: "stand", at: ms(-6), unread: 0, transport: .mesh, preview: "Toi : Parfait, je préviens la régie")
        message(model, group, from: lou, at: ms(-40), text: "Je suis au stand, la file commence à grossir", status: .delivered, transport: .mesh, hops: 1)
        var poll = AppMessage(id: UUIDv7.make(ms: ms(-30)), ts: ms(-30), kind: .poll)
        poll.poll = .init(question: "On mange où ce soir ?", options: [
            .init(id: "a", text: "Food truck thaï"), .init(id: "b", text: "Crêpes"), .init(id: "c", text: "Pizza au feu de bois"),
        ], multi: false)
        save(model, poll, conversation: group, from: nil, status: .read, transport: .mesh, hops: 2)
        model.db.updateState(poll.id) { state, _ in
            state.votes = [
                "": .init(ts: ms(-29), options: ["a"]), malik: .init(ts: ms(-25), options: ["a"]),
                lou: .init(ts: ms(-24), options: ["c"]), ines: .init(ts: ms(-20), options: ["a"]),
            ]
        }
        var live = AppMessage(id: UUIDv7.make(ms: ms(-14)), ts: ms(-14), kind: .location)
        live.location = .init(lat: here.latitude + 0.0012, lon: here.longitude - 0.0016, accuracyM: 8, liveUntil: Clock.nowMs + 47 * 60_000)
        save(model, live, conversation: group, from: ines, status: .delivered, transport: .mesh, hops: 2)
        model.db.updateState(live.id) { state, _ in
            state.live = .init(lat: here.latitude + 0.0009, lon: here.longitude - 0.0011, heading: nil, accuracyM: 8, ts: Clock.nowMs - 20_000, stopped: false)
        }
        let power = message(model, group, from: malik, at: ms(-8), text: "Le groupe électrogène repart à midi", status: .delivered, transport: .mesh, hops: 3)
        react(model, power, [ines: "👍", lou: "👍", "": "🙏"])
        var reply = AppMessage(id: UUIDv7.make(ms: ms(-6)), ts: ms(-6), kind: .text, text: "Parfait, je préviens la régie")
        reply.replyTo = power
        save(model, reply, conversation: group, from: nil, status: .read, transport: .mesh, hops: 2)

        let channel = AppModel.channelId("festival")
        conversation(model, id: channel, kind: .channel, title: "#festival", peer: "festival", at: ms(-18), unread: 0, transport: .mesh, preview: "Point d'eau ouvert derrière la grande scène")
        message(model, channel, from: lou, at: ms(-18), text: "Point d'eau ouvert derrière la grande scène", status: .delivered, transport: .mesh, hops: 4)

        let m = AppModel.directId(malik)
        conversation(model, id: m, kind: .direct, title: "Malik", peer: malik, at: ms(-55), unread: 1, transport: .node, preview: "Je passe le chargeur solaire ce soir")
        message(model, m, from: malik, at: ms(-60 * 26), text: "Tu as le plan du site pour demain ?", status: .delivered, transport: .node, hops: nil)
        message(model, m, from: nil, at: ms(-60 * 25.5), text: "Oui, je te l'envoie", status: .read, transport: .node, hops: nil)
        let pdf = planPDF()
        var doc = AppMessage(id: UUIDv7.make(ms: ms(-60 * 25.4)), ts: ms(-60 * 25.4), kind: .file)
        doc.attachment = .init(
            mime: "application/pdf", size: pdf.count, sha256: "", key: "", name: "Plan du site - Festival des Ondes.pdf",
            thumb: DocumentInfo.pdfThumbnail(pdf), pages: DocumentInfo.pdfPages(pdf))
        MediaStore.store(pdf, name: doc.id)
        save(model, doc, conversation: m, from: nil, status: .read, transport: .node, hops: nil, media: doc.id)
        react(model, doc.id, [malik: "🙏"])
        var link = AppMessage(id: UUIDv7.make(ms: ms(-62)), ts: ms(-62), kind: .text, text: "Le programme est en ligne : https://somalabs.me/relay")
        link.link = .init(
            url: "https://somalabs.me/relay", title: "Soma Relay : des messages qui passent même sans réseau",
            description: "Chiffré post-quantique, de téléphone en téléphone.", site: "somalabs.me", image: linkImage())
        save(model, link, conversation: m, from: malik, status: .delivered, transport: .node, hops: nil)
        let thanks = message(model, m, from: nil, at: ms(-58), text: "Merci ! Je regarde ça ce soir", status: .read, transport: .node, hops: nil)
        model.db.updateState(thanks) { state, _ in state.editedAt = ms(-57) }
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

    @discardableResult private static func message(
        _ model: AppModel, _ conversation: String, from: String?, at: Int64, text: String, status: DeliveryStatus, transport: Transport, hops: Int?, relays: Int? = nil
    ) -> String {
        let m = AppMessage(id: UUIDv7.make(ms: at), ts: at, kind: .text, text: text)
        save(model, m, conversation: conversation, from: from, status: status, transport: transport, hops: hops, relays: relays)
        return m.id
    }

    private static func save(
        _ model: AppModel, _ m: AppMessage, conversation: String, from: String?, status: DeliveryStatus, transport: Transport, hops: Int?,
        relays: Int? = nil, media: String? = nil
    ) {
        model.db.save(MessageRecord(
            id: m.id, conversationId: conversation, sender: from, ts: m.ts, kind: m.kind.rawValue, bodySealed: SecretBox.shared.seal(m.json()),
            status: status, transport: transport, hops: hops, relays: relays, replyTo: m.replyTo, mediaPath: media))
    }

    private static func react(_ model: AppModel, _ id: String, _ reactions: [String: String]) {
        model.db.updateState(id) { state, _ in state.reactions = reactions }
    }

    /// A three-page site plan, drawn here so the demo carries a real PDF.
    static func planPDF() -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ink = UIColor(hex: 0x111418, alpha: 1)
        let teal = UIColor(hex: 0x0B6E63, alpha: 1)
        let soft = UIColor(hex: 0xEEF1F5, alpha: 1)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { ctx in
            let titles = ["Plan du site", "Scènes et horaires", "Secours et points d'eau"]
            for (i, title) in titles.enumerated() {
                ctx.beginPage()
                let c = ctx.cgContext
                ("Festival des Ondes" as NSString).draw(at: CGPoint(x: 48, y: 48), withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: teal])
                (title as NSString).draw(at: CGPoint(x: 48, y: 68), withAttributes: [.font: UIFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: ink])
                soft.setFill()
                c.fill(CGRect(x: 48, y: 130, width: 499, height: 520))
                if i == 0 {
                    let stages: [(CGRect, String)] = [
                        (CGRect(x: 80, y: 160, width: 180, height: 110), "Grande scène"), (CGRect(x: 330, y: 170, width: 180, height: 90), "Scène des Ondes"),
                        (CGRect(x: 90, y: 420, width: 130, height: 90), "Stand 4"), (CGRect(x: 300, y: 430, width: 200, height: 160), "Village food"),
                    ]
                    for (rect, name) in stages {
                        (name == "Stand 4" ? teal : ink).withAlphaComponent(name == "Stand 4" ? 1 : 0.85).setFill()
                        c.fill(rect)
                        (name as NSString).draw(at: CGPoint(x: rect.minX + 10, y: rect.minY + 10), withAttributes: [.font: UIFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: UIColor.white])
                    }
                    teal.setStroke()
                    c.setLineWidth(4)
                    c.setLineDash(phase: 0, lengths: [10, 8])
                    c.move(to: CGPoint(x: 170, y: 270)); c.addLine(to: CGPoint(x: 160, y: 420)); c.strokePath()
                    c.move(to: CGPoint(x: 220, y: 465)); c.addLine(to: CGPoint(x: 300, y: 500)); c.strokePath()
                    c.setLineDash(phase: 0, lengths: [])
                } else {
                    for row in 0..<9 {
                        let y = 160 + CGFloat(row) * 54
                        UIColor.white.setFill()
                        c.fill(CGRect(x: 64, y: y, width: 467, height: 42))
                        let line = i == 1 ? String(format: "%02dh00   Scène %@   Artiste %d", 14 + row, row % 2 == 0 ? "A" : "B", row + 1)
                            : "Point \(row + 1)   \(row % 3 == 0 ? "Secours" : "Eau potable")   allée \(Character(UnicodeScalar(65 + row)!))"
                        (line as NSString).draw(at: CGPoint(x: 80, y: y + 12), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: ink])
                    }
                }
                ("Page \(i + 1) sur 3" as NSString).draw(at: CGPoint(x: 48, y: 790), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.gray])
            }
        }
    }

    /// The link preview picture: dark card with the relay arcs.
    static func linkImage() -> String? {
        let size = CGSize(width: 600, height: 315)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            UIColor(hex: 0x0C0E0D, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))
            let lime = UIColor(hex: 0xC6F24E, alpha: 1)
            for r in stride(from: 60.0, through: 300, by: 48) {
                lime.withAlphaComponent(0.12 + 0.5 * (1 - r / 300)).setStroke()
                c.setLineWidth(3)
                c.strokeEllipse(in: CGRect(x: 450 - r, y: 157 - r, width: 2 * r, height: 2 * r))
            }
            lime.setFill()
            c.fillEllipse(in: CGRect(x: 438, y: 145, width: 24, height: 24))
            ("Soma Relay" as NSString).draw(at: CGPoint(x: 40, y: 110), withAttributes: [.font: UIFont.systemFont(ofSize: 46, weight: .bold), .foregroundColor: UIColor.white])
            ("Même sans réseau." as NSString).draw(at: CGPoint(x: 42, y: 170), withAttributes: [.font: UIFont.systemFont(ofSize: 26, weight: .medium), .foregroundColor: lime])
        }
        return LinkPreviewer.shrink(image)?.base64EncodedString()
    }
}
