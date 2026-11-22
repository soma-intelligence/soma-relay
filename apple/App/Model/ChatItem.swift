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

    /// The mono line under the bubble (`MODIFIÉ · MESH 2 · LU`).
    var meta: String {
        let base = transportMeta
        return isEdited ? "MODIFIÉ · " + base : base
    }

    private var transportMeta: String {
        var parts: [String] = []
        switch transport {
        case .mesh: parts.append(hops.map { "MESH \($0)" } ?? "MESH")
        case .node: parts.append("NET")
        case .sms: parts.append("SMS")
        case .local: parts.append("LOCAL")
        }
        guard isMine else { return parts.joined(separator: " · ") }
        switch status {
        case .pending: return "EN ATTENTE · aucun lien"
        case .sent where transport == .mesh:
            let n = relays ?? 1
            return "EN ROUTE · confié à \(n) relais"
        case .sent: parts.append("ENVOYÉ")
        case .delivered: parts.append("REÇU")
        case .read: parts.append("LU")
        case .failed: return "ÉCHEC · touche pour réessayer"
        }
        return parts.joined(separator: " · ")
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
