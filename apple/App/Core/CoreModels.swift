import Foundation

// The JSON structs crossing the core boundary (spec section 5 and core-api.md).

nonisolated struct AppMessage: Codable, Equatable, Sendable {
    /// Every kind this client understands. Anything else decodes as `.unknown` and is ignored
    /// (spec v1.1: never "unreadable" for a kind we do not know).
    enum Kind: String, Codable, Sendable {
        case text, image, audio, video, file, receipt, typing, call, reaction, profile
        case groupOp = "group-op"
        case edit, delete, poll, location, settings
        case pollVote = "poll-vote"
        case locationUpdate = "location-update"
        case groupProfile = "group-profile"
        case groupLeave = "group-leave"
        case unknown

        init(from decoder: Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    var id: String
    var ts: Int64
    var kind: Kind
    var text: String?
    var replyTo: String?
    var attachment: Attachment?
    var receipt: Receipt?
    var call: CallSignal?
    var link: LinkPreview?
    var forwarded: Bool?
    var mentions: [String]?
    var expireS: Int?
    var poll: Poll?
    var vote: [String]?
    var close: Bool?
    var location: Location?
    var settings: Settings?
    /// `profile` (spec section 6): the sender's name and photo.
    var profile: Profile?
    /// `group-profile`: the group's name and photo, from an admin.
    var groupProfile: Profile?
    /// Synthetic `group-op` from the core: `{"id","event","name","members","admins"}`.
    var groupOp: GroupOp?

    enum CodingKeys: String, CodingKey {
        case id, ts, kind, text, attachment, receipt, call, link, forwarded, mentions, poll, vote, close, location, settings, profile
        case replyTo = "reply_to"
        case expireS = "expire_s"
        case groupProfile = "group_profile"
        case groupOp = "group"
    }

    init(
        id: String, ts: Int64, kind: Kind, text: String? = nil, replyTo: String? = nil, attachment: Attachment? = nil,
        receipt: Receipt? = nil, call: CallSignal? = nil
    ) {
        self.id = id
        self.ts = ts
        self.kind = kind
        self.text = text
        self.replyTo = replyTo
        self.attachment = attachment
        self.receipt = receipt
        self.call = call
    }

    /// Lenient: only `id` is required. A field of the wrong type is dropped, never fatal, so a
    /// newer client can add fields without breaking this one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ts = (try? c.decodeIfPresent(Int64.self, forKey: .ts)) ?? (try? c.decodeIfPresent(Double.self, forKey: .ts)).map { Int64($0) } ?? 0
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .unknown
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        replyTo = try? c.decodeIfPresent(String.self, forKey: .replyTo)
        attachment = try? c.decodeIfPresent(Attachment.self, forKey: .attachment)
        receipt = try? c.decodeIfPresent(Receipt.self, forKey: .receipt)
        call = try? c.decodeIfPresent(CallSignal.self, forKey: .call)
        link = try? c.decodeIfPresent(LinkPreview.self, forKey: .link)
        forwarded = try? c.decodeIfPresent(Bool.self, forKey: .forwarded)
        mentions = try? c.decodeIfPresent([String].self, forKey: .mentions)
        expireS = try? c.decodeIfPresent(Int.self, forKey: .expireS)
        poll = try? c.decodeIfPresent(Poll.self, forKey: .poll)
        vote = try? c.decodeIfPresent([String].self, forKey: .vote)
        close = try? c.decodeIfPresent(Bool.self, forKey: .close)
        location = try? c.decodeIfPresent(Location.self, forKey: .location)
        settings = try? c.decodeIfPresent(Settings.self, forKey: .settings)
        profile = try? c.decodeIfPresent(Profile.self, forKey: .profile)
        groupProfile = try? c.decodeIfPresent(Profile.self, forKey: .groupProfile)
        groupOp = try? c.decodeIfPresent(GroupOp.self, forKey: .groupOp)
    }

    /// `{ name?, avatar?: base64 JPEG | null, avatar_hash? }`. A missing `avatar` keeps the photo,
    /// `null` removes it, so the three states survive a round trip.
    nonisolated struct Profile: Codable, Equatable, Sendable {
        enum Avatar: Equatable, Sendable {
            case keep, remove
            case set(String)
        }
        var name: String?
        var avatar: Avatar = .keep
        var avatarHash: String?

        enum CodingKeys: String, CodingKey {
            case name, avatar
            case avatarHash = "avatar_hash"
        }

        init(name: String? = nil, avatar: Avatar = .keep, avatarHash: String? = nil) {
            self.name = name
            self.avatar = avatar
            self.avatarHash = avatarHash
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            avatarHash = try? c.decodeIfPresent(String.self, forKey: .avatarHash)
            if c.contains(.avatar) {
                if (try? c.decodeNil(forKey: .avatar)) == true {
                    avatar = .remove
                } else if let text = try? c.decode(String.self, forKey: .avatar) {
                    avatar = .set(text)
                }
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(name, forKey: .name)
            switch avatar {
            case .keep: break
            case .remove: try c.encodeNil(forKey: .avatar)
            case .set(let text): try c.encode(text, forKey: .avatar)
            }
            try c.encodeIfPresent(avatarHash, forKey: .avatarHash)
        }
    }

    nonisolated struct GroupOp: Codable, Equatable, Sendable {
        var id: String
        var event: String?
        var name: String?
        var members: [String]?
        var admins: [String]?
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
        /// Documents: page count (PDF), when the sender knows it.
        var pages: Int?

        enum CodingKeys: String, CodingKey {
            case mime, size, sha256, key, name, width, height, thumb, inline, url, levels, pages
            case durationMs = "duration_ms"
        }

        init(
            mime: String, size: Int, sha256: String, key: String, name: String? = nil, width: Int? = nil, height: Int? = nil,
            durationMs: Int? = nil, thumb: String? = nil, inline: String? = nil, url: String? = nil, levels: [Float]? = nil,
            pages: Int? = nil
        ) {
            self.mime = mime
            self.size = size
            self.sha256 = sha256
            self.key = key
            self.name = name
            self.width = width
            self.height = height
            self.durationMs = durationMs
            self.thumb = thumb
            self.inline = inline
            self.url = url
            self.levels = levels
            self.pages = pages
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mime = (try? c.decodeIfPresent(String.self, forKey: .mime)) ?? "application/octet-stream"
            size = (try? c.decodeIfPresent(Int.self, forKey: .size)) ?? 0
            sha256 = (try? c.decodeIfPresent(String.self, forKey: .sha256)) ?? ""
            key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? ""
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            width = try? c.decodeIfPresent(Int.self, forKey: .width)
            height = try? c.decodeIfPresent(Int.self, forKey: .height)
            durationMs = try? c.decodeIfPresent(Int.self, forKey: .durationMs)
            thumb = try? c.decodeIfPresent(String.self, forKey: .thumb)
            inline = try? c.decodeIfPresent(String.self, forKey: .inline)
            url = try? c.decodeIfPresent(String.self, forKey: .url)
            levels = try? c.decodeIfPresent([Float].self, forKey: .levels)
            pages = try? c.decodeIfPresent(Int.self, forKey: .pages)
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

    /// Link preview built by the sender (the receiver never fetches anything).
    nonisolated struct LinkPreview: Codable, Equatable, Sendable {
        var url: String
        var title: String?
        var description: String?
        var site: String?
        /// Base64 JPEG, longest side 600 px, at most 40 KiB.
        var image: String?
    }

    nonisolated struct Poll: Codable, Equatable, Sendable {
        nonisolated struct Option: Codable, Equatable, Sendable, Identifiable {
            var id: String
            var text: String
        }
        var question: String
        var options: [Option]
        var multi: Bool
        var closesAt: Int64?

        enum CodingKeys: String, CodingKey {
            case question, options, multi
            case closesAt = "closes_at"
        }

        init(question: String, options: [Option], multi: Bool, closesAt: Int64? = nil) {
            self.question = question
            self.options = options
            self.multi = multi
            self.closesAt = closesAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            question = (try? c.decodeIfPresent(String.self, forKey: .question)) ?? ""
            options = (try? c.decodeIfPresent([Option].self, forKey: .options)) ?? []
            multi = (try? c.decodeIfPresent(Bool.self, forKey: .multi)) ?? false
            closesAt = try? c.decodeIfPresent(Int64.self, forKey: .closesAt)
        }
    }

    nonisolated struct Location: Codable, Equatable, Sendable {
        var lat: Double
        var lon: Double
        var accuracyM: Double?
        var name: String?
        var address: String?
        var liveUntil: Int64?
        var heading: Double?
        var stop: Bool?

        enum CodingKeys: String, CodingKey {
            case lat, lon, name, address, heading, stop
            case accuracyM = "accuracy_m"
            case liveUntil = "live_until"
        }

        init(lat: Double, lon: Double, accuracyM: Double? = nil, name: String? = nil, address: String? = nil, liveUntil: Int64? = nil, heading: Double? = nil, stop: Bool? = nil) {
            self.lat = lat
            self.lon = lon
            self.accuracyM = accuracyM
            self.name = name
            self.address = address
            self.liveUntil = liveUntil
            self.heading = heading
            self.stop = stop
        }
    }

    nonisolated struct Settings: Codable, Equatable, Sendable {
        var expireS: Int?

        enum CodingKeys: String, CodingKey {
            case expireS = "expire_s"
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
    /// Mailbox of each member (hex), same order as `members`.
    var mailboxes: [String]? = nil
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

extension Array {
    nonisolated subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
