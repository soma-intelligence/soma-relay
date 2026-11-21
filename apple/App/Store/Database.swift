import Foundation
import GRDB

/// Where a message travelled (drives the bubble colour and the mono metadata).
nonisolated enum Transport: String, Codable, Sendable, DatabaseValueConvertible {
    case mesh, node, sms, local
}

nonisolated enum DeliveryStatus: String, Codable, Sendable, DatabaseValueConvertible {
    /// Not handed to any link yet (dashed bubble).
    case pending
    /// Handed to mesh relays or the node mailbox.
    case sent
    case delivered
    case read
    case failed
}

nonisolated enum ConversationKind: String, Codable, Sendable, DatabaseValueConvertible {
    case direct, group, channel
}

nonisolated struct ConversationRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "conversation"
    var id: String
    var kind: ConversationKind
    var title: String
    var peer: String?
    var lastAt: Int64
    var unread: Int
    var lastTransport: Transport?
    var previewSealed: Data?
    var muted: Bool = false
    /// Disappearing messages timer in seconds (0 = off), set by a `settings` message.
    var expireS: Int = 0
    /// Muted until this time (ms). 0 = not muted, `Int64.max` = always.
    var mutedUntil: Int64 = 0

    func isMuted(now: Int64 = Clock.nowMs) -> Bool { mutedUntil > now }
}

nonisolated struct MessageRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "message"
    var id: String
    var conversationId: String
    /// nil = me.
    var sender: String?
    var ts: Int64
    var kind: String
    /// The whole AppMessage JSON, sealed.
    var bodySealed: Data
    var status: DeliveryStatus
    var transport: Transport
    var hops: Int?
    var relays: Int?
    var replyTo: String?
    /// Sealed local copy of the attachment (relative path in the media folder).
    var mediaPath: String?
    /// Sealed `MessageState` JSON: reactions, edits, delete, poll votes, live location.
    var stateSealed: Data? = nil
    /// Disappearing timer carried by the message (seconds), and when it goes (ms). The clock
    /// starts when the reader first sees it (sender: when sent).
    var expireS: Int? = nil
    var expireAt: Int64? = nil
}

nonisolated struct OutboxRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "outbox"
    var id: String
    var messageId: String?
    /// Mailbox (hex) for node delivery, empty for mesh-only frames.
    var mailbox: String
    var peer: String?
    var envelope: Data
    var createdAt: Int64
    var attempts: Int
    var meshOnly: Bool
}

/// SQLite through GRDB. Every message body and preview is sealed by `SecretBox`; the file itself
/// has complete file protection.
final class AppDatabase {
    let queue: DatabaseQueue
    let box = SecretBox.shared

    nonisolated static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SomaRelay", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = base
        try? url.setResourceValues(values)
        return base
    }

    init(inMemory: Bool = false) throws {
        if inMemory {
            queue = try DatabaseQueue()
        } else {
            let url = Self.directory().appendingPathComponent("relay.sqlite")
            queue = try DatabaseQueue(path: url.path)
            // Until first unlock (not complete): pushes and background refresh must open it while
            // the phone is locked. Bodies are sealed by SecretBox anyway.
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        }
        try migrator.migrate(queue)
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "conversation") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("peer", .text)
                t.column("lastAt", .integer).notNull()
                t.column("unread", .integer).notNull().defaults(to: 0)
                t.column("lastTransport", .text)
                t.column("previewSealed", .blob)
                t.column("muted", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "message") { t in
                t.primaryKey("id", .text)
                t.column("conversationId", .text).notNull().indexed()
                t.column("sender", .text)
                t.column("ts", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("bodySealed", .blob).notNull()
                t.column("status", .text).notNull()
                t.column("transport", .text).notNull()
                t.column("hops", .integer)
                t.column("relays", .integer)
                t.column("replyTo", .text)
                t.column("mediaPath", .text)
            }
            try db.create(table: "outbox") { t in
                t.primaryKey("id", .text)
                t.column("messageId", .text)
                t.column("mailbox", .text).notNull()
                t.column("peer", .text)
                t.column("envelope", .blob).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("meshOnly", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "kv") { t in
                t.primaryKey("key", .text)
                t.column("value", .blob).notNull()
            }
        }
        m.registerMigration("v2-messaging") { db in
            try db.alter(table: "message") { t in
                t.add(column: "stateSealed", .blob)
                t.add(column: "expireS", .integer)
                t.add(column: "expireAt", .integer)
            }
            try db.create(index: "message_expireAt", on: "message", columns: ["expireAt"])
            try db.create(index: "message_conversation_ts", on: "message", columns: ["conversationId", "ts"])
            try db.alter(table: "conversation") { t in
                t.add(column: "expireS", .integer).notNull().defaults(to: 0)
                t.add(column: "mutedUntil", .integer).notNull().defaults(to: 0)
            }
        }
        return m
    }

    // MARK: Key-value (sealed)

    func setValue(_ data: Data?, for key: String) {
        try? queue.write { db in
            if let data {
                try db.execute(sql: "INSERT OR REPLACE INTO kv(key, value) VALUES (?, ?)", arguments: [key, box.seal(data)])
            } else {
                try db.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [key])
            }
        }
    }

    func value(for key: String) -> Data? {
        let sealed = try? queue.read { db in try Data.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key]) }
        return sealed.flatMap { box.open($0) }
    }

    // MARK: Conversations and messages

    func conversations() -> [ConversationRecord] {
        (try? queue.read { db in try ConversationRecord.order(Column("lastAt").desc).fetchAll(db) }) ?? []
    }

    func conversation(_ id: String) -> ConversationRecord? {
        try? queue.read { db in try ConversationRecord.fetchOne(db, key: id) }
    }

    func save(_ conversation: ConversationRecord) {
        try? queue.write { db in try conversation.save(db) }
    }

    func deleteConversation(_ id: String) {
        try? queue.write { db in
            _ = try ConversationRecord.deleteOne(db, key: id)
            try db.execute(sql: "DELETE FROM message WHERE conversationId = ?", arguments: [id])
        }
    }

    func messages(in conversationId: String, limit: Int = 500) -> [MessageRecord] {
        let rows = (try? queue.read { db in
            try MessageRecord.filter(Column("conversationId") == conversationId).order(Column("ts").desc).limit(limit).fetchAll(db)
        }) ?? []
        return rows.reversed()
    }

    func message(_ id: String) -> MessageRecord? {
        try? queue.read { db in try MessageRecord.fetchOne(db, key: id) }
    }

    func save(_ message: MessageRecord) {
        try? queue.write { db in try message.save(db) }
    }

    func deleteMessage(_ id: String) {
        try? queue.write { db in _ = try MessageRecord.deleteOne(db, key: id) }
    }

    /// Opened state of a message (empty when none).
    func state(of record: MessageRecord) -> MessageState {
        record.stateSealed.flatMap { box.open($0) }.flatMap { try? JSONDecoder().decode(MessageState.self, from: $0) } ?? MessageState()
    }

    /// Read-modify-write of a message state. Returns the record after the change, nil when the
    /// message is unknown.
    @discardableResult func updateState(_ id: String, _ change: (inout MessageState, inout MessageRecord) -> Void) -> MessageRecord? {
        guard var record = message(id) else { return nil }
        var state = state(of: record)
        change(&state, &record)
        record.stateSealed = (try? JSONEncoder().encode(state)).map { box.seal($0) }
        save(record)
        return record
    }

    /// Messages whose disappearing timer ran out.
    func expiredMessages(now: Int64) -> [MessageRecord] {
        (try? queue.read { db in
            try MessageRecord.filter(Column("expireAt") != nil && Column("expireAt") <= now).fetchAll(db)
        }) ?? []
    }

    /// Incoming messages with a timer whose clock has not started (not seen yet).
    func unstartedTimers(in conversationId: String) -> [MessageRecord] {
        (try? queue.read { db in
            try MessageRecord.filter(Column("conversationId") == conversationId && Column("expireS") != nil && Column("expireAt") == nil)
                .fetchAll(db)
        }) ?? []
    }

    func nextExpiry() -> Int64? {
        try? queue.read { db in try Int64.fetchOne(db, sql: "SELECT MIN(expireAt) FROM message WHERE expireAt IS NOT NULL") }
    }

    /// Every message, newest first, for local search (bodies are opened by the caller).
    func allMessages(limit: Int = 20_000) -> [MessageRecord] {
        (try? queue.read { db in try MessageRecord.order(Column("ts").desc).limit(limit).fetchAll(db) }) ?? []
    }

    func hasMessage(_ id: String) -> Bool {
        ((try? queue.read { db in try MessageRecord.exists(db, key: id) }) ?? false)
    }

    func updateStatus(ids: [String], to status: DeliveryStatus, hops: Int? = nil) {
        try? queue.write { db in
            for id in ids {
                guard var m = try MessageRecord.fetchOne(db, key: id), m.sender == nil else { continue }
                if Self.rank(status) > Self.rank(m.status) { m.status = status }
                if let hops { m.hops = hops }
                try m.update(db)
            }
        }
    }

    nonisolated static func rank(_ s: DeliveryStatus) -> Int {
        switch s {
        case .failed: 0
        case .pending: 1
        case .sent: 2
        case .delivered: 3
        case .read: 4
        }
    }

    // MARK: Outbox

    func enqueue(_ item: OutboxRecord) {
        try? queue.write { db in try item.save(db) }
    }

    func outbox() -> [OutboxRecord] {
        (try? queue.read { db in try OutboxRecord.order(Column("createdAt")).fetchAll(db) }) ?? []
    }

    func removeOutbox(_ id: String) {
        try? queue.write { db in _ = try OutboxRecord.deleteOne(db, key: id) }
    }

    func wipe() {
        try? queue.write { db in
            try db.execute(sql: "DELETE FROM conversation; DELETE FROM message; DELETE FROM outbox; DELETE FROM kv;")
        }
    }
}
