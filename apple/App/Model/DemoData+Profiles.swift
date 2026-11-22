import Foundation
import UIKit

/// v1.2 demo data: profile photos (drawn here, no real faces), a new contact with unread
/// messages, and a message that lands while the app is open (`-RelayDemoScreen banner`).
extension DemoData {
    static let jade = "d4c3b2a1f0e9d8c7b6a5f4e3d2c1b0a9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d403"

    static func seedProfiles(_ model: AppModel) {
        let now = Clock.nowMs
        model.contacts.append(ContactJSON(
            fingerprint: jade, name: "Jade", mailbox: "a5", verified: false, nodeUrl: AppModel.defaultNodeURL, handle: "jade", addedAt: now - 3_600_000))
        let art: [(String, UInt32, UInt32, String)] = [
            (AppModel.me, 0x0B6E63, 0xC6F24E, "🏔️"),
            (ines, 0xF2709C, 0xFF9472, "🌻"),
            (malik, 0x1E4FD0, 0x6DD5FA, "🎧"),
            (nadia, 0x7F53AC, 0x647DEE, "🪴"),
            (jade, 0x11998E, 0x38EF7D, "🌊"),
            (AppModel.groupPhotoKey("stand"), 0xF7971E, 0xFFD200, "🎪"),
        ]
        for (owner, a, b, glyph) in art {
            if let data = ProfilePhoto.encode(avatarArt(a, b, glyph)) { model.storePhoto(data, owner: owner) }
        }

        let calendar = Calendar.current
        let base = calendar.date(bySettingHour: 10, minute: 42, second: 0, of: Date()) ?? Date()
        func ms(_ minutes: Double) -> Int64 { Int64((base.timeIntervalSince1970 + minutes * 60) * 1000) }
        let j = AppModel.directId(jade)
        model.db.save(ConversationRecord(
            id: j, kind: .direct, title: "Jade", peer: jade, lastAt: ms(6), unread: 2, lastTransport: .mesh,
            previewSealed: SecretBox.shared.seal("Tu peux me garder une place devant ?")))
        for (minutes, text) in [(5.0, "Je viens de t'ajouter par le mesh"), (6.0, "Tu peux me garder une place devant ?")] {
            let m = AppMessage(id: UUIDv7.make(ms: ms(minutes)), ts: ms(minutes), kind: .text, text: text)
            model.db.save(MessageRecord(
                id: m.id, conversationId: j, sender: jade, ts: m.ts, kind: "text", bodySealed: SecretBox.shared.seal(m.json()),
                status: .delivered, transport: .mesh, hops: 1, relays: nil, replyTo: nil, mediaPath: nil))
        }
        // The group grew: Jade joined and Inès set the photo.
        let group = AppModel.groupId("stand")
        for (minutes, code, from) in [(-50.0, "photo", ines)] {
            let m = AppMessage(id: UUIDv7.make(ms: ms(minutes)), ts: ms(minutes), kind: .groupOp, text: code)
            model.db.save(MessageRecord(
                id: m.id, conversationId: group, sender: from, ts: m.ts, kind: m.kind.rawValue, bodySealed: SecretBox.shared.seal(m.json()),
                status: .read, transport: .local, hops: nil, relays: nil, replyTo: nil, mediaPath: nil))
        }
        if let i = model.groups.firstIndex(where: { $0.id == "stand" }) {
            model.groups[i].members.append(model.core?.fingerprintHex() ?? "")
            model.groups[i].admins.append(model.core?.fingerprintHex() ?? "")
        }
    }

    /// `banner`: a message from Nadia lands two seconds after launch, then one from Inès.
    static func runLiveDemo(_ model: AppModel) {
        guard let screen, screen == "banner" || screen == "live" else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            incoming(model, from: nadia, text: "Je suis au point d'eau, tu me rejoins ?")
            guard screen == "live" else { return }
            try? await Task.sleep(for: .seconds(5))
            incoming(model, from: ines, text: "Le concert commence dans 10 min")
        }
    }

    private static func incoming(_ model: AppModel, from fp: String, text: String) {
        let message = AppMessage.make(.text, text: text)
        model.store(InboundJSON(from: fp, group: nil, channel: nil, message: message, envelopeId: UUID().uuidString), transport: .mesh, hops: 1)
    }

    /// A square picture: soft two-colour gradient and a big glyph.
    static func avatarArt(_ a: UInt32, _ b: UInt32, _ glyph: String) -> UIImage {
        let size = CGSize(width: 512, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let colors = [UIColor(hex: a, alpha: 1).cgColor, UIColor(hex: b, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let font = UIFont.systemFont(ofSize: 250)
            let text = glyph as NSString
            let box = text.size(withAttributes: [.font: font])
            text.draw(at: CGPoint(x: (size.width - box.width) / 2, y: (size.height - box.height) / 2 + 8), withAttributes: [.font: font])
        }
    }

    /// What the camera "sees" in the simulator: a festival stage at dusk.
    static func cameraScene() -> UIImage {
        let size = CGSize(width: 1080, height: 1440)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            let sky = [UIColor(hex: 0x1B2A49, alpha: 1).cgColor, UIColor(hex: 0xF29E6D, alpha: 1).cgColor, UIColor(hex: 0xF7D488, alpha: 1).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sky, locations: [0, 0.62, 1]) {
                c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height * 0.8), options: [.drawsAfterEndLocation])
            }
            UIColor(hex: 0xFFE7B0, alpha: 0.9).setFill()
            c.fillEllipse(in: CGRect(x: 690, y: 640, width: 210, height: 210))
            UIColor(hex: 0x14161A, alpha: 1).setFill()
            c.fill(CGRect(x: 0, y: 1050, width: size.width, height: 390))
            // Stage and lights.
            c.fill(CGRect(x: 180, y: 760, width: 720, height: 300))
            c.move(to: CGPoint(x: 140, y: 770)); c.addLine(to: CGPoint(x: 540, y: 640)); c.addLine(to: CGPoint(x: 940, y: 770)); c.fillPath()
            for i in 0..<7 {
                UIColor(hex: [0xC6F24E, 0xFF9472, 0x6DD5FA][i % 3], alpha: 0.35).setFill()
                let x = 220 + CGFloat(i) * 105
                c.move(to: CGPoint(x: x, y: 790)); c.addLine(to: CGPoint(x: x - 90, y: 1050)); c.addLine(to: CGPoint(x: x + 90, y: 1050)); c.fillPath()
            }
            // Crowd.
            UIColor(hex: 0x0B0C0E, alpha: 1).setFill()
            for i in 0..<24 {
                let x = CGFloat(i) * 48 - 10
                let h = CGFloat(60 + (i * 37) % 70)
                c.fillEllipse(in: CGRect(x: x, y: 1080 - h * 0.5, width: 56, height: 56))
                c.fill(CGRect(x: x + 4, y: 1110 - h * 0.5 + 20, width: 48, height: 400))
            }
        }
    }
}
