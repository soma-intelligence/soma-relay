import Foundation
import SwiftUI

/// Where a chat opens: the conversation and, from a search hit or a notification, a message to
/// scroll to.
struct ChatRoute: Hashable {
    var conversationId: String
    var focus: String?
}

/// A live location share I am running.
struct LiveShare: Equatable {
    var conversationId: String
    var until: Int64
}

/// One local search result.
struct SearchHit: Identifiable, Hashable {
    var conversationId: String
    var messageId: String
    var title: String
    var snippet: String
    var ts: Int64
    var id: String { messageId }
}

/// v1.1 messaging (spec 2026-11-21-v1.1-messaging.md section 1): reactions, edit and delete for
/// everyone, forward, polls, location, disappearing messages, mute, mentions and local search.
extension AppModel {
    static let reactionChoices = ["👍", "❤️", "😂", "😮", "😢", "🙏"]
    static let timerChoices = [0, 300, 3600, 86_400, 604_800]
    static let editWindowMs: Int64 = 86_400_000

    // MARK: Reactions

    /// Sets my reaction (one per message). The same emoji again removes it.
    func react(_ emoji: String, to item: ChatItem) {
        let current = item.state.reactions[""]
        let next = current == emoji ? "" : emoji
        db.updateState(item.id) { state, _ in
            if next.isEmpty { state.reactions[""] = nil } else { state.reactions[""] = next }
        }
        Haptics.tap()
        messageVersion += 1
        var message = AppMessage.make(.reaction, text: next)
        message.replyTo = item.id
        deliver(message, in: item.conversationId)
    }

    func applyReaction(_ inbound: InboundJSON) {
        guard let target = inbound.message.replyTo, let record = db.message(target),
            record.conversationId == conversationId(of: inbound)
        else { return }
        let emoji = inbound.message.text ?? ""
        db.updateState(target) { state, _ in
            if emoji.isEmpty { state.reactions[inbound.from] = nil } else { state.reactions[inbound.from] = emoji }
        }
        if !emoji.isEmpty, record.sender == nil, activeConversation != record.conversationId,
            db.conversation(record.conversationId)?.isMuted() != true
        {
            let item = ChatItem(record: record, senderName: nil)
            Notifier.shared.post(
                conversationId: record.conversationId, title: db.conversation(record.conversationId)?.title ?? name(of: inbound.from),
                sender: nil, body: "\(name(of: inbound.from)) a réagi \(emoji) à « \(item.summary.prefix(40)) »", messageId: inbound.message.id,
                muted: false)
        }
        messageVersion += 1
    }

    // MARK: Edit

    func canEdit(_ item: ChatItem) -> Bool {
        item.isMine && !item.isDeleted && item.message.kind == .text && Clock.nowMs - item.message.ts < Self.editWindowMs
            && !item.conversationId.hasPrefix("c:")
    }

    func edit(_ item: ChatItem, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit(item), !trimmed.isEmpty, trimmed != item.message.text else { return }
        replaceText(of: item.id, with: trimmed, at: Clock.nowMs)
        var message = AppMessage.make(.edit, text: trimmed)
        message.replyTo = item.id
        deliver(message, in: item.conversationId)
        refreshPreview(item.conversationId)
    }

    func applyEdit(_ inbound: InboundJSON) {
        guard let target = inbound.message.replyTo, let record = db.message(target), let text = inbound.message.text,
            record.sender == inbound.from, record.conversationId == conversationId(of: inbound), record.kind == "text",
            inbound.message.ts - record.ts <= Self.editWindowMs
        else { return }
        replaceText(of: target, with: text, at: inbound.message.ts)
        refreshPreview(record.conversationId)
    }

    private func replaceText(of id: String, with text: String, at ts: Int64) {
        db.updateState(id) { state, record in
            guard !state.isDeleted, var body = SecretBox.shared.openText(record.bodySealed).flatMap(AppMessage.decode) else { return }
            body.text = text
            body.link = body.link.flatMap { text.contains($0.url) ? $0 : nil }
            record.bodySealed = SecretBox.shared.seal(body.json())
            state.editedAt = ts
        }
        messageVersion += 1
    }

    // MARK: Delete

    func canDeleteForEveryone(_ item: ChatItem) -> Bool {
        item.isMine && !item.isDeleted && !item.isSystem && !item.conversationId.hasPrefix("c:")
    }

    func deleteForEveryone(_ item: ChatItem) {
        guard canDeleteForEveryone(item) else { return }
        tombstone(item.id)
        if liveShares[item.id] != nil { stopLive(item.id) }
        var message = AppMessage.make(.delete)
        message.replyTo = item.id
        deliver(message, in: item.conversationId)
        Haptics.warning()
    }

    func deleteForMe(_ item: ChatItem) {
        if let path = item.mediaPath { MediaStore.remove(path) }
        if liveShares[item.id] != nil { stopLive(item.id) }
        db.deleteMessage(item.id)
        refreshPreview(item.conversationId)
        messageVersion += 1
    }

    func applyDelete(_ inbound: InboundJSON) {
        guard let target = inbound.message.replyTo, let record = db.message(target), record.sender == inbound.from,
            record.conversationId == conversationId(of: inbound)
        else { return }
        tombstone(target)
    }

    /// "Message supprimé": the body loses its content, the media leaves the disk.
    private func tombstone(_ id: String) {
        guard let record = db.message(id) else { return }
        if let path = record.mediaPath { MediaStore.remove(path) }
        db.updateState(id) { state, record in
            let body = AppMessage(id: record.id, ts: record.ts, kind: .text)
            record.bodySealed = SecretBox.shared.seal(body.json())
            record.kind = "text"
            record.mediaPath = nil
            state = MessageState(deleted: true)
        }
        refreshPreview(record.conversationId)
        messageVersion += 1
    }

    /// The conversation preview follows its last visible message (after edits, deletes, expiry).
    func refreshPreview(_ conversationId: String) {
        guard var c = db.conversation(conversationId) else { return }
        let last = db.messages(in: conversationId, limit: 1).last.map { ChatItem(record: $0, senderName: nil) }
        let text = last.map { item -> String in
            guard c.kind != .direct, let sender = item.sender, !item.isSystem else { return item.summary }
            return "\(name(of: sender)) : \(item.summary)"
        } ?? ""
        c.previewSealed = SecretBox.shared.seal(text)
        db.save(c)
        reloadConversations()
    }

    // MARK: Forward

    func canForward(_ item: ChatItem) -> Bool {
        !item.isDeleted && !item.isSystem && item.message.kind != .poll
    }

    /// Re-sends to another conversation with `forwarded: true`. Media keeps its key and blob URL
    /// (no re-upload); the local copy is duplicated for the new message.
    func forward(_ item: ChatItem, to conversationId: String) {
        guard canForward(item) else { return }
        var message = AppMessage.make(item.message.kind, text: item.message.text)
        message.attachment = item.message.attachment
        message.link = item.message.link
        message.forwarded = true
        if var location = item.message.location {
            if let live = item.state.live { location.lat = live.lat; location.lon = live.lon }
            location.liveUntil = nil
            message.location = location
        }
        var mediaPath: String?
        if let path = item.mediaPath, let plain = MediaStore.load(path) {
            mediaPath = MediaStore.store(plain, name: message.id)
        }
        if conversationId.hasPrefix("c:"), message.attachment != nil {
            banner = "Les canaux locaux n'acceptent que du texte."
            return
        }
        post(message, in: conversationId, preview: Self.previewText(message), mediaPath: mediaPath)
        banner = "Transféré."
    }

    // MARK: Polls

    func sendPoll(question: String, options: [String], multi: Bool, in conversationId: String) {
        let cleaned = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, (2...12).contains(cleaned.count) else { return }
        let ids = "abcdefghijkl".map(String.init)
        var message = AppMessage.make(.poll)
        message.poll = .init(question: q, options: cleaned.enumerated().map { .init(id: ids[$0.offset], text: $0.element) }, multi: multi)
        post(message, in: conversationId, preview: Self.previewText(message))
    }

    func isClosed(_ item: ChatItem) -> Bool {
        if item.state.closedAt != nil { return true }
        if let closes = item.message.poll?.closesAt, Clock.nowMs > closes { return true }
        return false
    }

    /// Tap on an option: toggles it (multi) or picks it (single). Picking my current single
    /// choice again retracts the vote.
    func vote(_ optionId: String, in item: ChatItem) {
        guard let poll = item.message.poll, !isClosed(item), !item.isDeleted else { return }
        var mine = item.state.myVote
        if poll.multi {
            if let i = mine.firstIndex(of: optionId) { mine.remove(at: i) } else { mine.append(optionId) }
        } else {
            mine = mine == [optionId] ? [] : [optionId]
        }
        let now = Clock.nowMs
        db.updateState(item.id) { state, _ in state.votes[""] = .init(ts: now, options: mine) }
        Haptics.select()
        messageVersion += 1
        var message = AppMessage.make(.pollVote)
        message.replyTo = item.id
        message.vote = mine
        deliver(message, in: item.conversationId)
    }

    func closePoll(_ item: ChatItem) {
        guard item.isMine, item.message.kind == .poll, !isClosed(item) else { return }
        let now = Clock.nowMs
        db.updateState(item.id) { state, _ in state.closedAt = now }
        Haptics.success()
        messageVersion += 1
        var message = AppMessage.make(.pollVote)
        message.replyTo = item.id
        message.vote = []
        message.close = true
        deliver(message, in: item.conversationId)
    }

    func applyVote(_ inbound: InboundJSON) {
        let m = inbound.message
        guard let target = m.replyTo, let record = db.message(target), record.kind == "poll",
            record.conversationId == conversationId(of: inbound)
        else { return }
        let poll = SecretBox.shared.openText(record.bodySealed).flatMap(AppMessage.decode)?.poll
        let valid = Set(poll?.options.map(\.id) ?? [])
        db.updateState(target) { state, _ in
            if m.close == true {
                // Only the creator closes.
                if record.sender == inbound.from, state.closedAt == nil { state.closedAt = m.ts }
                return
            }
            if let closed = state.closedAt, m.ts > closed { return }
            if let closes = poll?.closesAt, m.ts > closes { return }
            if let previous = state.votes[inbound.from], previous.ts > m.ts { return }
            var options = (m.vote ?? []).filter { valid.contains($0) }
            if poll?.multi != true { options = Array(options.prefix(1)) }
            state.votes[inbound.from] = .init(ts: m.ts, options: options)
        }
        messageVersion += 1
    }

    // MARK: Location

    /// Static pin, or a live share for `live` seconds (15 min, 1 h, 8 h).
    func sendLocation(lat: Double, lon: Double, accuracy: Double?, live: TimeInterval?, in conversationId: String) {
        var message = AppMessage.make(.location)
        let until = live.map { Clock.nowMs + Int64($0 * 1000) }
        message.location = .init(lat: lat, lon: lon, accuracyM: accuracy, liveUntil: until)
        post(message, in: conversationId, preview: Self.previewText(message))
        if let until {
            liveShares[message.id] = LiveShare(conversationId: conversationId, until: until)
            db.updateState(message.id) { state, _ in
                state.live = .init(lat: lat, lon: lon, heading: nil, accuracyM: accuracy, ts: Clock.nowMs, stopped: false)
            }
            locationSharer.startLive()
        }
    }

    /// Called by the location sharer (at most every 10 s, after 10 m).
    func sendLocationUpdate(_ location: AppMessage.Location) {
        let now = Clock.nowMs
        for (id, share) in liveShares {
            guard share.until > now else {
                stopLive(id)
                continue
            }
            db.updateState(id) { state, _ in
                state.live = .init(lat: location.lat, lon: location.lon, heading: location.heading, accuracyM: location.accuracyM, ts: now, stopped: false)
            }
            var message = AppMessage.make(.locationUpdate)
            message.replyTo = id
            message.location = location
            deliver(message, in: share.conversationId)
        }
        messageVersion += 1
    }

    func stopLive(_ id: String) {
        guard let share = liveShares.removeValue(forKey: id) else { return }
        let last = db.message(id).map { db.state(of: $0).live } ?? nil
        db.updateState(id) { state, _ in
            if state.live != nil { state.live?.stopped = true; state.live?.ts = Clock.nowMs }
        }
        var message = AppMessage.make(.locationUpdate)
        message.replyTo = id
        message.location = .init(lat: last?.lat ?? 0, lon: last?.lon ?? 0, stop: true)
        deliver(message, in: share.conversationId)
        if liveShares.isEmpty { locationSharer.stopLive() }
        messageVersion += 1
    }

    func applyLocationUpdate(_ inbound: InboundJSON) {
        let m = inbound.message
        guard let target = m.replyTo, let loc = m.location, let record = db.message(target), record.sender == inbound.from,
            record.conversationId == conversationId(of: inbound),
            let original = SecretBox.shared.openText(record.bodySealed).flatMap(AppMessage.decode)?.location,
            let until = original.liveUntil
        else { return }
        if loc.stop != true, m.ts > until { return }
        db.updateState(target) { state, _ in
            if let live = state.live, live.ts > m.ts { return }
            let lat = loc.stop == true ? (state.live?.lat ?? original.lat) : loc.lat
            let lon = loc.stop == true ? (state.live?.lon ?? original.lon) : loc.lon
            state.live = .init(lat: lat, lon: lon, heading: loc.heading, accuracyM: loc.accuracyM, ts: m.ts, stopped: loc.stop == true)
        }
        messageVersion += 1
    }

    /// Current pin of a location message: the live position when there is one.
    static func coordinate(of item: ChatItem) -> (lat: Double, lon: Double)? {
        if let live = item.state.live { return (live.lat, live.lon) }
        return item.message.location.map { ($0.lat, $0.lon) }
    }

    static func isLive(_ item: ChatItem, now: Int64 = Clock.nowMs) -> Bool {
        guard let until = item.message.location?.liveUntil else { return false }
        return until > now && item.state.live?.stopped != true
    }

    // MARK: Disappearing messages

    static func timerLabel(_ seconds: Int) -> String {
        switch seconds {
        case 0: "désactivés"
        case 300: "5 min"
        case 3600: "1 h"
        case 86_400: "1 jour"
        case 604_800: "1 semaine"
        default: seconds < 3600 ? "\(seconds / 60) min" : seconds < 86_400 ? "\(seconds / 3600) h" : "\(seconds / 86_400) j"
        }
    }

    static func timerSentence(_ seconds: Int, by name: String?) -> String {
        let who = name ?? "Tu"
        let verb = name == nil ? "as" : "a"
        if seconds == 0 { return "\(who) \(verb) désactivé les messages éphémères" }
        return "\(who) \(verb) réglé les messages éphémères sur \(timerLabel(seconds))"
    }

    func setTimer(_ seconds: Int, in conversationId: String) {
        guard var c = db.conversation(conversationId), c.expireS != seconds, c.kind != .channel else { return }
        c.expireS = seconds
        db.save(c)
        var message = AppMessage.make(.settings)
        message.settings = .init(expireS: seconds)
        post(message, in: conversationId, preview: Self.previewText(message))
        Haptics.select()
    }

    func applySettings(_ inbound: InboundJSON, transport: Transport, hops: Int?) {
        guard let seconds = inbound.message.settings?.expireS, inbound.channel == nil else { return }
        let id = conversationId(of: inbound)
        store(inbound, transport: transport, hops: hops)
        guard var c = db.conversation(id) else { return }
        c.expireS = max(0, seconds)
        db.save(c)
        reloadConversations()
    }

    /// The reader's clock starts when the conversation is on screen.
    func startTimers(in conversationId: String) {
        let now = Clock.nowMs
        let records = db.unstartedTimers(in: conversationId)
        guard !records.isEmpty else { return }
        for var record in records where record.sender != nil {
            record.expireAt = now + Int64(record.expireS ?? 0) * 1000
            db.save(record)
        }
        scheduleExpiry()
    }

    /// Deletes what expired, then sleeps until the next expiry (at most a minute).
    func runExpiry() {
        let now = Clock.nowMs
        let expired = db.expiredMessages(now: now)
        var touched = Set<String>()
        for record in expired {
            if let path = record.mediaPath { MediaStore.remove(path) }
            if liveShares[record.id] != nil { stopLive(record.id) }
            db.deleteMessage(record.id)
            touched.insert(record.conversationId)
        }
        for id in touched { refreshPreview(id) }
        if !expired.isEmpty { messageVersion += 1 }
        scheduleExpiry()
    }

    func scheduleExpiry() {
        expiryTask?.cancel()
        guard let next = db.nextExpiry() else { return }
        let delay = max(0.5, min(60, Double(next - Clock.nowMs) / 1000))
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.runExpiry()
        }
    }

    // MARK: Mute

    func mute(_ conversationId: String, for seconds: TimeInterval?) {
        guard var c = db.conversation(conversationId) else { return }
        if let seconds {
            c.mutedUntil = seconds <= 0 ? 0 : Clock.nowMs + Int64(seconds * 1000)
        } else {
            c.mutedUntil = .max
        }
        c.muted = c.mutedUntil > 0
        db.save(c)
        reloadConversations()
        Haptics.select()
    }

    static func muteLabel(_ c: ConversationRecord) -> String? {
        guard c.isMuted() else { return nil }
        if c.mutedUntil == .max { return "Sourdine" }
        let date = Date(timeIntervalSince1970: Double(c.mutedUntil) / 1000)
        return "Sourdine jusqu'à " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Locale(identifier: "fr_FR")))
    }

    // MARK: Mentions

    /// `@Name` of a group member in the text -> their fingerprint.
    func mentions(in text: String, conversationId: String) -> [String]? {
        guard conversationId.hasPrefix("g:"), text.contains("@"),
            let group = groups.first(where: { Self.groupId($0.id) == conversationId })
        else { return nil }
        let me = core?.fingerprintHex()
        let found = group.members.filter { fp in
            guard fp != me, let name = contact(fp)?.name, !name.isEmpty else { return false }
            return text.range(of: "@" + name, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return found.isEmpty ? nil : found
    }

    // MARK: Search (local only)

    /// Conversations by name and messages by text, newest first.
    func search(_ query: String, limit: Int = 60) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let titles = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0.title) })
        let now = Clock.nowMs
        var hits: [SearchHit] = []
        for record in db.allMessages() where (record.expireAt ?? .max) > now {
            let item = ChatItem(record: record, senderName: nil)
            guard !item.isDeleted, !item.isSystem else { continue }
            let haystack = [item.message.text, item.message.poll?.question, item.message.attachment?.name, item.message.link?.title]
                .compactMap { $0 }.joined(separator: " ")
            guard let range = haystack.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            hits.append(SearchHit(
                conversationId: record.conversationId, messageId: record.id, title: titles[record.conversationId] ?? "",
                snippet: Self.snippet(haystack, around: range), ts: record.ts))
            if hits.count >= limit { break }
        }
        return hits
    }

    /// Ids of the messages of one conversation that match, oldest first.
    func searchIds(_ query: String, in items: [ChatItem]) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return items.filter { item in
            guard !item.isDeleted else { return false }
            let text = [item.message.text, item.message.poll?.question, item.message.attachment?.name].compactMap { $0 }.joined(separator: " ")
            return text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }.map(\.id)
    }

    static func snippet(_ text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        let core = text[start..<end].replacingOccurrences(of: "\n", with: " ")
        return (start > text.startIndex ? "…" : "") + core + (end < text.endIndex ? "…" : "")
    }
}
