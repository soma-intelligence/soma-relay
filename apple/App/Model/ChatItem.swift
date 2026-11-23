import Foundation

/// One message as the chat view draws it (opened from its sealed record).
struct ChatItem: Identifiable, Equatable {
    let id: String
    let message: AppMessage
    /// nil = me.
    let sender: String?
    let senderName: String?
    let status: DeliveryStatus
    let transport: Transport
    let hops: Int?
    let relays: Int?
    let mediaPath: String?
    let state: MessageState
    let expireAt: Int64?
    let conversationId: String

    var isMine: Bool { sender == nil }
    var isDeleted: Bool { state.isDeleted }
    var isEdited: Bool { state.editedAt != nil && !isDeleted }
    /// System lines (timer changes, group changes) are drawn centered, not as bubbles.
    var isSystem: Bool { message.kind == .settings || message.kind == .groupOp }

    init(record: MessageRecord, senderName: String?, state: MessageState? = nil) {
        id = record.id
        message = SecretBox.shared.openText(record.bodySealed).flatMap(AppMessage.decode)
            ?? AppMessage(id: record.id, ts: record.ts, kind: .text, text: "Message illisible")
        self.state = state ?? record.stateSealed.flatMap { SecretBox.shared.open($0) }
            .flatMap { try? JSONDecoder().decode(MessageState.self, from: $0) } ?? MessageState()
        expireAt = record.expireAt
        conversationId = record.conversationId
        sender = record.sender
        self.senderName = senderName
        status = record.status
        transport = record.transport
        hops = record.hops
        relays = record.relays
        mediaPath = record.mediaPath
    }

    /// Outgoing message not confirmed yet: drawn dashed.
    var isInFlight: Bool {
        isMine && (status == .pending || (status == .sent && transport == .mesh))
    }

    /// Text shown for this message in quotes, previews and VoiceOver.
    var summary: String {
        if isDeleted { return "Message supprimé" }
        return message.kind == .text ? (message.text ?? "") : AppModel.previewText(message)
    }

    var time: String {
        Date(timeIntervalSince1970: Double(message.ts) / 1000).formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "fr_FR")))
    }

    /// What the line under the last bubble of a run says, in plain words ("Mesh · Lu",
    /// "En route, confié à 3 relais", "Par le nœud · Reçu", "SMS").
    struct Meta: Hashable {
        enum Tone { case plain, sms, warning }
        var icon: String?
        var text: String
        var tone: Tone = .plain
    }

    var meta: Meta {
        var m = transportMeta
        if isEdited { m.text = "Modifié · " + m.text }
        return m
    }

    /// Transport glyph and name, as the design system writes them.
    static func transportName(_ transport: Transport) -> (icon: String?, name: String) {
        switch transport {
        case .mesh: ("point.3.connected.trianglepath.dotted", "Mesh")
        case .node: ("globe", "Par le nœud")
        case .sms: ("message.fill", "SMS")
        case .local: (nil, "Canal local")
        }
    }

    private var transportMeta: Meta {
        let t = Self.transportName(transport)
        let tone: Meta.Tone = transport == .sms ? .sms : .plain
        guard isMine else {
            return Meta(icon: t.icon, text: transport == .local ? time : t.name + " · " + time, tone: tone)
        }
        switch status {
        case .pending: return Meta(icon: "hourglass", text: "En attente d'un lien")
        case .sent where transport == .mesh:
            let n = relays ?? 1
            return Meta(icon: "hourglass", text: "En route, confié à \(n) relais")
        case .sent: return Meta(icon: t.icon, text: transport == .local ? "Envoyé · " + time : t.name + " · Envoyé", tone: tone)
        case .delivered: return Meta(icon: t.icon, text: t.name + " · Reçu", tone: tone)
        case .read: return Meta(icon: t.icon, text: t.name + " · Lu", tone: tone)
        case .failed: return Meta(icon: "exclamationmark.circle.fill", text: "Échec, touche Réessayer", tone: .warning)
        }
    }

    var accessibilityStatus: String {
        guard isMine else { return "" }
        switch status {
        case .pending: return "en attente d'un lien"
        case .sent: return transport == .mesh ? "en route par le mesh" : "envoyé"
        case .delivered: return "reçu"
        case .read: return "lu"
        case .failed: return "échec de l'envoi"
        }
    }
}

/// How the last message from a contact reached us: feeds the path card.
struct PathInfo: Equatable {
    var transport: Transport
    var hops: Int?
    /// Short code of the neighbour that handed us the frame (`K7`).
    var via: String?
    var at: Date
}
