import Foundation

/// What happened to a message after it was stored: reactions, edit, delete for everyone, poll
/// votes and the live location pin. Kept sealed next to the message (`stateSealed`).
nonisolated struct MessageState: Codable, Equatable, Sendable {
    /// Voter fingerprint (`""` = me) -> emoji. One reaction per person.
    var reactions: [String: String] = [:]
    var editedAt: Int64?
    var deleted: Bool?
    /// Voter fingerprint (`""` = me) -> latest vote.
    var votes: [String: Vote] = [:]
    var closedAt: Int64?
    var live: Live?

    nonisolated struct Vote: Codable, Equatable, Sendable {
        var ts: Int64
        var options: [String]
    }

    nonisolated struct Live: Codable, Equatable, Sendable {
        var lat: Double
        var lon: Double
        var heading: Double?
        var accuracyM: Double?
        var ts: Int64
        var stopped: Bool
    }

    var isDeleted: Bool { deleted == true }

    /// Reactions grouped for the pill: emoji, count, and whether mine is among them. Most used first.
    var reactionSummary: [(emoji: String, count: Int, mine: Bool)] {
        var counts: [String: (Int, Bool)] = [:]
        for (who, emoji) in reactions where !emoji.isEmpty {
            let current = counts[emoji] ?? (0, false)
            counts[emoji] = (current.0 + 1, current.1 || who.isEmpty)
        }
        return counts.map { (emoji: $0.key, count: $0.value.0, mine: $0.value.1) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.emoji < $1.emoji }
    }

    /// Option id -> number of voters.
    func tally() -> [String: Int] {
        var out: [String: Int] = [:]
        for vote in votes.values {
            for option in Set(vote.options) { out[option, default: 0] += 1 }
        }
        return out
    }

    var voterCount: Int { votes.values.filter { !$0.options.isEmpty }.count }

    var myVote: [String] { votes[""]?.options ?? [] }
}
