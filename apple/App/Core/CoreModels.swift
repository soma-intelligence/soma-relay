import Foundation

// The JSON structs crossing the core boundary (spec section 5 and core-api.md).

nonisolated struct AppMessage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text, image, audio, video, file, receipt, typing, call, reaction, profile
        case groupOp = "group-op"
    }

    var id: String
    var ts: Int64
    var kind: Kind
    var text: String?
    var replyTo: String?
    var attachment: Attachment?
    var receipt: Receipt?
    var call: CallSignal?

    enum CodingKeys: String, CodingKey {
        case id, ts, kind, text, attachment, receipt, call
        case replyTo = "reply_to"
    }

    nonisolated struct Attachment: Codable, Equatable, Sendable {
        var mime: String
        var size: Int
        var sha256: String
        var key: String
        var name: String?
        var width: Int?
        var height: Int?
        var durationMs: Int?
        var thumb: String?
        var inline: String?
        var url: String?
        /// Voice notes: 48 levels in 0...1 for the waveform (client extension, ignored by others).
        var levels: [Float]?

        enum CodingKeys: String, CodingKey {
            case mime, size, sha256, key, name, width, height, thumb, inline, url, levels
            case durationMs = "duration_ms"
        }
    }

    nonisolated struct Receipt: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable { case delivered, read }
        var of: [String]
        var state: State
        /// Mesh hops the original took (client extension).
        var hops: Int?
    }

    nonisolated struct CallSignal: Codable, Equatable, Sendable {
        enum Action: String, Codable, Sendable { case offer, answer, ice, end, decline, busy }
        var callId: String
        var action: Action
        var sdp: String?
        var candidate: String?
        var video: Bool

        enum CodingKeys: String, CodingKey {
            case action, sdp, candidate, video
            case callId = "call_id"
        }
    }

    static func make(_ kind: Kind, text: String? = nil) -> AppMessage {
        AppMessage(id: UUIDv7.make(), ts: Clock.nowMs, kind: kind, text: text)
    }

    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "{}"
    }

    static func decode(_ json: String) -> AppMessage? {
        try? JSONDecoder().decode(AppMessage.self, from: Data(json.utf8))
    }
}

nonisolated struct ContactJSON: Codable, Equatable, Sendable, Identifiable {
    var fingerprint: String
    var name: String
    var mailbox: String
    var verified: Bool
    var nodeUrl: String?
    var handle: String?
    var addedAt: Int64

    var id: String { fingerprint }

    enum CodingKeys: String, CodingKey {
        case fingerprint, name, mailbox, verified, handle
        case nodeUrl = "node_url"
        case addedAt = "added_at"
    }
}

nonisolated struct InboundJSON: Codable, Sendable {
    var from: String
    var group: String?
    var channel: String?
    var message: AppMessage
    var envelopeId: String

    enum CodingKeys: String, CodingKey {
        case from, group, channel, message
        case envelopeId = "envelope_id"
    }
}

nonisolated struct CompactJSON: Codable, Sendable {
    var fingerprint: String
    var nodeUrl: String?
    var handle: String?

    enum CodingKeys: String, CodingKey {
        case fingerprint, handle
        case nodeUrl = "node_url"
    }
}

nonisolated struct GroupJSON: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var name: String
    var members: [String]
    var admins: [String]
}

nonisolated enum JSON {
    static func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(text.utf8))
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "null"
    }
}

nonisolated enum Clock {
    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

/// UUID v7 (time ordered), as the spec asks for message ids.
nonisolated enum UUIDv7 {
    static func make(ms: Int64 = Clock.nowMs) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { bytes[i] = UInt8.random(in: 0...255) }
        let t = UInt64(ms)
        for i in 0..<6 { bytes[i] = UInt8((t >> (8 * (5 - UInt64(i)))) & 0xFF) }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }
}

nonisolated extension Data {
    init?(base64url: String) {
        var s = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }

    var base64url: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(bytes: chars[i..<i + 2], encoding: .ascii) ?? "", radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        self = out
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

nonisolated extension String {
    /// `4F2A·91C0·77DE·...` grouping of a hex fingerprint.
    func groupedFingerprint(groups: Int = 4) -> String {
        let upper = uppercased()
        var parts: [String] = []
        var index = upper.startIndex
        while index < upper.endIndex, parts.count < groups {
            let end = upper.index(index, offsetBy: 4, limitedBy: upper.endIndex) ?? upper.endIndex
            parts.append(String(upper[index..<end]))
            index = end
        }
        return parts.joined(separator: "·")
    }
}
