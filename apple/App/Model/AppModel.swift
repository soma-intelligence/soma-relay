import Foundation
import Observation
import SwiftUI
import UserNotifications

/// The whole app state: identity (core), storage, transports and calls. Main actor only.
@Observable
final class AppModel {
    enum Phase: Equatable { case loading, onboarding, ready }

    static var defaultNodeURL: String { AppConfig.defaultNodeURL }

    var phase: Phase = .loading
    private(set) var core: RelayCoreAPI?
    let db: AppDatabase

    var contacts: [ContactJSON] = []
    var groups: [GroupJSON] = []
    var channels: [String] = []
    var conversations: [ConversationRecord] = []
    var nearby: [NearbyPeer] = []
    var meshPeerCount = 0
    var nodeState: NodeClient.State = .off
    var nodeOnline: Set<String> = []
    var typingUntil: [String: Date] = [:]
    var routes: [String: PathInfo] = [:]
    /// Bumped whenever messages change, so open chats reload.
    var messageVersion = 0
    var activeConversation: String?
    /// A contact just added: the QR tile turns into the safety words for them.
    var justAdded: ContactJSON?
    var banner: String?
    /// The glass banner for a message that lands in another conversation than the open one.
    var messageBanner: MessageBanner?
    /// Profile photos: contact fingerprint, "me", or "g:<group id>" -> image (spec section 6).
    var photos: [String: UIImage] = [:]
    /// Group names set by a `group-profile` (they override the core op log name).
    var groupNames: [String: String] = [:]
    /// A conversation to open (notification tap, search hit), with an optional message to show.
    var openRequest: ChatRoute?
    /// Live location shares I am running: location message id -> conversation.
    var liveShares: [String: LiveShare] = [:]
    @ObservationIgnored var expiryTask: Task<Void, Never>?
    @ObservationIgnored lazy var locationSharer = LocationSharer(model: self)

    /// Link previews on send (Settings, on by default).
    var linkPreviews: Bool {
        didSet { UserDefaults.standard.set(linkPreviews, forKey: "linkPreviews") }
    }
    /// Sender and text in notifications (off: "Nouveau message").
    var notificationPreviews: Bool {
        didSet { UserDefaults.standard.set(notificationPreviews, forKey: "notificationPreviews") }
    }

    var nodeURL: String {
        didSet {
            UserDefaults.standard.set(nodeURL, forKey: "nodeURL")
            if let url = URL(string: nodeURL) { node.setBaseURL(url) }
        }
    }
    var handle: String {
        didSet { UserDefaults.standard.set(handle, forKey: "handle") }
    }
    var visibleNearby: Bool {
        didSet {
            UserDefaults.standard.set(visibleNearby, forKey: "visibleNearby")
            restartMesh()
        }
    }
    var nodeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(nodeEnabled, forKey: "nodeEnabled")
            if nodeEnabled { node.connect() } else { node.disconnect() }
        }
    }

    let mesh = MeshTransport()
    private(set) var node: NodeClient!
    private var meshRouter: MeshRouterAPI?
    private(set) var calls: CallManager!
    let demo: Bool
    private var saveTask: Task<Void, Never>?
    private var lastTypingSent: [String: Date] = [:]
    @ObservationIgnored private var heldGroup: [HeldEnvelope] = []
    @ObservationIgnored var lastNodeEnvelope = Date.distantPast

    private struct HeldEnvelope {
        var env: Data
        var transport: Transport
        var hops: Int?
        var ingress: String?
        var at: Date
    }

    init() {
        let args = UserDefaults.standard
        demo = AppConfig.demoAllowed && args.bool(forKey: "RelayDemoData")
        nodeURL = args.string(forKey: "nodeURL") ?? Self.defaultNodeURL
        handle = args.string(forKey: "handle") ?? ""
        visibleNearby = args.object(forKey: "visibleNearby") as? Bool ?? true
        nodeEnabled = args.object(forKey: "nodeEnabled") as? Bool ?? true
        linkPreviews = args.object(forKey: "linkPreviews") as? Bool ?? true
        notificationPreviews = args.object(forKey: "notificationPreviews") as? Bool ?? true
        db = (try? AppDatabase(inMemory: demo)) ?? (try! AppDatabase(inMemory: true))
        node = NodeClient(
            baseURL: URL(string: nodeURL) ?? URL(string: Self.defaultNodeURL)!,
            core: { [weak self] in self?.core },
            card: { [weak self] in self?.myCard })
        node.delegate = self
        mesh.delegate = self
        calls = CallManager(model: self)
    }

    var displayName: String { core?.displayName() ?? "" }
    var usesRealCore: Bool { RelayCoreFactory.usesRealCore }

    var myCard: String? {
        core?.myCard(nodeUrl: nodeEnabled ? nodeURL : nil, handle: handle.isEmpty ? nil : handle)
    }

    var myCompactLink: String? { core?.myCompactLink(nodeUrl: nodeEnabled ? nodeURL : nil) }

    // MARK: Launch

    func start() {
        guard phase == .loading else { return }
        Notifier.shared.model = self
        if demo {
            DemoData.seed(self)
            phase = .ready
            DemoData.runLiveDemo(self)
            return
        }
        if let state = db.value(for: "engine"), let restored = try? RelayCoreFactory.restore(state: state) {
            core = restored
            didLoadCore()
            phase = .ready
            runExpiry()
        } else {
            phase = .onboarding
        }
    }

    /// Onboarding: new identity.
    func createIdentity(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Let the "keys being generated" state draw before the work (milliseconds in practice).
        try? await Task.sleep(for: .milliseconds(60))
        core = RelayCoreFactory.create(displayName: trimmed)
        saveNow()
        didLoadCore()
    }

    func finishOnboarding() {
        withAnimation(.smooth) { phase = .ready }
        Notifier.shared.requestAuthorization()
    }

    /// For tests and demo data.
    func adoptCore(_ engine: RelayCoreAPI) {
        core = engine
    }

    private func didLoadCore() {
        guard let core else { return }
        meshRouter = core.makeMeshRouter()
        (core as? MockRelayCore)?.setHandle(handle.isEmpty ? nil : handle, node: nodeEnabled ? nodeURL : nil)
        if core.rotatePrekeyIfDue(nowMs: Clock.nowMs) { scheduleSave() }
        loadPhotos()
        reloadContacts()
        reloadConversations()
        restartMesh()
        if nodeEnabled { node.connect() }
        Notifier.shared.registerForPush()
    }

    func restartMesh() {
        guard core != nil, !demo else { return }
        mesh.start(visibleName: visibleNearby ? displayName : nil, compactLink: visibleNearby ? myCompactLink : nil)
    }

    // MARK: Persistence

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let core, !demo else { return }
        db.setValue(core.exportState(), for: "engine")
    }

    func reloadContacts() {
        guard let core, !demo else { return }
        contacts = JSON.decode([ContactJSON].self, core.contacts()) ?? []
        groups = JSON.decode([GroupJSON].self, core.groups()) ?? []
        channels = (UserDefaults.standard.stringArray(forKey: "channels") ?? [])
    }

    func reloadConversations() {
        conversations = db.conversations()
        updateBadge()
    }

    private func updateBadge() {
        let unread = conversations.reduce(0) { $0 + $1.unread }
        UNUserNotificationCenter.current().setBadgeCount(unread) { _ in }
    }

    func contact(_ fp: String) -> ContactJSON? { contacts.first { $0.fingerprint == fp } }

    func name(of fp: String?) -> String {
        guard let fp else { return "Toi" }
        return contact(fp)?.name ?? "Inconnu " + String(fp.prefix(4)).uppercased()
    }

    // MARK: Conversations

    static func directId(_ fp: String) -> String { "d:" + fp }
    static func groupId(_ id: String) -> String { "g:" + id }
    static func channelId(_ name: String) -> String { "c:" + name }

    func preview(of conversation: ConversationRecord) -> String {
        SecretBox.shared.openText(conversation.previewSealed) ?? ""
    }

    @discardableResult func openDirect(_ fp: String) -> ConversationRecord {
        let id = Self.directId(fp)
        if let existing = db.conversation(id) { return existing }
        let c = ConversationRecord(id: id, kind: .direct, title: name(of: fp), peer: fp, lastAt: Clock.nowMs, unread: 0, lastTransport: nil, previewSealed: nil)
        db.save(c)
        reloadConversations()
        return c
    }

    func markRead(_ conversationId: String) {
        guard var c = db.conversation(conversationId) else { return }
        let hadUnread = c.unread > 0
        c.unread = 0
        db.save(c)
        reloadConversations()
        startTimers(in: conversationId)
        Notifier.shared.clear(conversationId)
        // Read receipts for direct chats.
        guard hadUnread || true, c.kind == .direct, let fp = c.peer, !demo else { return }
        let unreadIds = db.messages(in: conversationId, limit: 50).filter { $0.sender != nil && $0.status != .read }.map(\.id)
        guard !unreadIds.isEmpty else { return }
        var records = db.messages(in: conversationId, limit: 50)
        for i in records.indices where unreadIds.contains(records[i].id) {
            records[i].status = .read
            db.save(records[i])
        }
        var receipt = AppMessage.make(.receipt)
        receipt.receipt = .init(of: unreadIds, state: .read, hops: nil)
        sendControl(receipt, to: fp)
    }

    func deleteConversation(_ id: String) {
        db.deleteConversation(id)
        reloadConversations()
    }

    func items(in conversationId: String) -> [ChatItem] {
        let conv = db.conversation(conversationId)
        let now = Clock.nowMs
        return db.messages(in: conversationId).filter { ($0.expireAt ?? .max) > now }.map { record in
            ChatItem(record: record, senderName: conv?.kind == .direct ? nil : record.sender.map { name(of: $0) })
        }
    }

    func isTyping(_ conversationId: String) -> Bool {
        (typingUntil[conversationId] ?? .distantPast) > Date()
    }

    // MARK: Sending

    /// Text (and replies) to a conversation.
    func send(text: String, in conversationId: String, replyTo: String? = nil, link: AppMessage.LinkPreview? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var message = AppMessage.make(.text, text: trimmed)
        message.replyTo = replyTo
        message.mentions = mentions(in: trimmed, conversationId: conversationId)
        message.link = link
        post(message, in: conversationId, preview: trimmed)
    }

    /// Stores then delivers an outgoing message. Stamps the conversation timer on it.
    func post(_ message: AppMessage, in conversationId: String, preview: String, mediaPath: String? = nil) {
        var message = message
        let timer = db.conversation(conversationId)?.expireS ?? 0
        if timer > 0, message.kind != .settings { message.expireS = timer }
        let record = MessageRecord(
            id: message.id, conversationId: conversationId, sender: nil, ts: message.ts, kind: message.kind.rawValue,
            bodySealed: SecretBox.shared.seal(message.json()), status: .pending, transport: .local, hops: nil, relays: nil,
            replyTo: message.replyTo, mediaPath: mediaPath, expireS: message.expireS,
            expireAt: message.expireS.map { message.ts + Int64($0) * 1000 })
        db.save(record)
        if record.expireAt != nil { scheduleExpiry() }
        touch(conversationId, preview: preview, transport: nil, incoming: false)
        Haptics.soft()
        deliver(message, in: conversationId)
    }

    func retry(_ messageId: String) {
        guard let record = db.message(messageId), let item = Optional(ChatItem(record: record, senderName: nil)) else { return }
        deliver(item.message, in: record.conversationId)
    }

    func deliver(_ message: AppMessage, in conversationId: String) {
        guard let core, let conv = db.conversation(conversationId) else { return }
        do {
            switch conv.kind {
            case .direct:
                guard let fp = conv.peer, let contact = contact(fp) else { return }
                let env = try core.encryptFor(fp: fp, appMessageJson: message.json())
                scheduleSave()
                let result = route(env, to: contact, messageId: message.id)
                update(message.id, transport: result.transport, status: result.status, relays: result.relays)
            case .group:
                guard let gid = conv.peer, let group = groups.first(where: { $0.id == gid }) else { return }
                let envs = try core.groupEncrypt(groupId: gid, appMessageJson: message.json())
                scheduleSave()
                var best: (transport: Transport, status: DeliveryStatus, relays: Int?) = (.local, .pending, nil)
                let sent = fanOutGroup(envs, group: group, messageId: message.id)
                if sent.node { best = (.node, .sent, nil) } else if sent.mesh > 0 { best = (.mesh, .sent, sent.mesh) }
                update(message.id, transport: best.transport, status: best.status, relays: best.relays)
            case .channel:
                guard let name = conv.peer else { return }
                let env = core.channelEncrypt(name: name, password: nil, appMessageJson: message.json())
                let n = broadcastMesh(env)
                update(message.id, transport: .mesh, status: n > 0 ? .delivered : .pending, relays: n)
            }
        } catch {
            update(message.id, transport: .local, status: .failed, relays: nil)
            banner = error.message
        }
    }

    struct RouteResult {
        var transport: Transport
        var status: DeliveryStatus
        var relays: Int?
    }

    /// Router: open P2P link (mesh) and node mailbox; when neither is up, the outbox keeps it
    /// (courier) and the chat offers SMS.
    func route(_ env: Data, to contact: ContactJSON, messageId: String?) -> RouteResult {
        guard let core else { return RouteResult(transport: .local, status: .failed) }
        var relays = 0
        if meshPeerCount > 0 {
            relays = broadcastMesh(core.retagForMesh(envelope: env, fp: contact.fingerprint, nowMs: Clock.nowMs))
        }
        if nodeEnabled, node.send(envelope: env, to: contact.mailbox) {
            return RouteResult(transport: relays > 0 && nodeOnline.contains(contact.mailbox) == false ? .mesh : .node, status: .sent, relays: relays)
        }
        // Keep it for the node and for phones met later.
        enqueue(env, mailbox: contact.mailbox, peer: contact.fingerprint, messageId: messageId)
        if relays > 0 { return RouteResult(transport: .mesh, status: .sent, relays: relays) }
        return RouteResult(transport: .local, status: .pending)
    }

    @discardableResult func broadcastMesh(_ env: Data) -> Int {
        guard let meshRouter, meshPeerCount > 0 else { return 0 }
        mesh.broadcast(meshRouter.framesFor(envelope: env, mtu: MeshTransport.mtu))
        return meshPeerCount
    }

    func enqueue(_ env: Data, mailbox: String, peer: String?, messageId: String?) {
        db.enqueue(OutboxRecord(id: UUID().uuidString, messageId: messageId, mailbox: mailbox, peer: peer, envelope: env, createdAt: Clock.nowMs, attempts: 0, meshOnly: false))
    }

    func update(_ id: String, transport: Transport, status: DeliveryStatus, relays: Int?) {
        guard var record = db.message(id) else { return }
        record.transport = transport
        record.status = status
        record.relays = relays
        db.save(record)
        if let c = db.conversation(record.conversationId), transport != .local {
            var c = c
            c.lastTransport = transport
            db.save(c)
            reloadConversations()
        }
        messageVersion += 1
    }

    /// Receipts, typing and call signals: not stored.
    func sendControl(_ message: AppMessage, to fp: String) {
        guard let core, let contact = contact(fp), let env = try? core.encryptFor(fp: fp, appMessageJson: message.json()) else { return }
        scheduleSave()
        if meshPeerCount > 0 { broadcastMesh(core.retagForMesh(envelope: env, fp: fp, nowMs: Clock.nowMs)) }
        if nodeEnabled { node.send(envelope: env, to: contact.mailbox) }
    }

    func userIsTyping(in conversationId: String) {
        guard let conv = db.conversation(conversationId), conv.kind == .direct, let fp = conv.peer else { return }
        if let last = lastTypingSent[conversationId], Date().timeIntervalSince(last) < 3 { return }
        lastTypingSent[conversationId] = Date()
        guard meshPeerCount > 0 || node.isReady else { return }
        sendControl(AppMessage.make(.typing), to: fp)
    }

    /// Flushes the outbox to the node and replays it on the mesh.
    private func flushOutbox(toNode: Bool, toMesh: Bool) {
        guard let core else { return }
        for item in db.outbox() {
            if Clock.nowMs - item.createdAt > 14 * 86_400_000 {
                db.removeOutbox(item.id)
                continue
            }
            if toMesh, let peer = item.peer {
                broadcastMesh(core.retagForMesh(envelope: item.envelope, fp: peer, nowMs: Clock.nowMs))
                if let id = item.messageId { update(id, transport: .mesh, status: .sent, relays: meshPeerCount) }
            }
            if toNode, node.send(envelope: item.envelope, to: item.mailbox) {
                db.removeOutbox(item.id)
                if let id = item.messageId, db.message(id)?.status ?? .sent < .sent { update(id, transport: .node, status: .sent, relays: nil) }
            }
        }
    }

    /// The envelope of a pending message as an encrypted SMS link (text only, <= 1 KiB envelope).
    func smsLink(for messageId: String) -> String? {
        guard let item = db.outbox().first(where: { $0.messageId == messageId }), item.envelope.count <= 1100 else { return nil }
        return AppConfig.smsLinkBase + item.envelope.base64url
    }

    func markSentBySMS(_ messageId: String) {
        update(messageId, transport: .sms, status: .sent, relays: nil)
    }

    // MARK: Receiving

    /// Keeps a group envelope whose sender key has not arrived yet (at most 128, for one day).
    private func holdGroupEnvelope(_ env: Data, via transport: Transport, hops: Int?, ingress: String?) {
        guard !heldGroup.contains(where: { $0.env == env }) else { return }
        heldGroup.append(HeldEnvelope(env: env, transport: transport, hops: hops, ingress: ingress, at: Date()))
        if heldGroup.count > 128 { heldGroup.removeFirst(heldGroup.count - 128) }
    }

    /// After a direct envelope (it may carry a sender key), try the held group envelopes again.
    private func retryHeldGroupEnvelopes() {
        guard let core, !heldGroup.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        let pending = heldGroup.filter { $0.at > cutoff }
        heldGroup = []
        for held in pending {
            if let json = (try? core.open(envelope: held.env, nowMs: Clock.nowMs)) ?? nil {
                handleOpened(json, via: held.transport, hops: held.hops, ingress: held.ingress)
            } else {
                heldGroup.append(held)
            }
        }
        scheduleSave()
    }

    func handleEnvelope(_ env: Data, via transport: Transport, hops: Int? = nil, ingress: String? = nil) {
        guard let core else { return }
        let isGroup = core.envelopeKind(env) == "group"
        let json: String?
        do {
            json = try core.open(envelope: env, nowMs: Clock.nowMs)
        } catch {
            // A group message that lands before its sender key: keep it, retry later.
            if isGroup, case .noSession = error { holdGroupEnvelope(env, via: transport, hops: hops, ingress: ingress) }
            return
        }
        scheduleSave()
        if let json {
            handleOpened(json, via: transport, hops: hops, ingress: ingress)
        } else if isGroup {
            holdGroupEnvelope(env, via: transport, hops: hops, ingress: ingress)
        }
        if !isGroup { retryHeldGroupEnvelopes() }
    }

    private func handleOpened(_ json: String, via transport: Transport, hops: Int?, ingress: String?) {
        guard let inbound = JSON.decode(InboundJSON.self, json) else { return }

        let known = contact(inbound.from) != nil
        if !known { reloadContacts() }
        if inbound.channel == nil {
            routes[inbound.from] = PathInfo(transport: transport, hops: hops, via: ingress, at: Date())
        }
        let message = inbound.message
        switch message.kind {
        case .receipt:
            if let receipt = message.receipt {
                db.updateStatus(ids: receipt.of, to: receipt.state == .read ? .read : .delivered, hops: receipt.hops)
                for id in receipt.of { db.outbox().filter { $0.messageId == id }.forEach { db.removeOutbox($0.id) } }
                messageVersion += 1
            }
        case .typing:
            typingUntil[Self.directId(inbound.from)] = Date().addingTimeInterval(5)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5.2))
                self?.messageVersion += 0
                self?.typingUntil = self?.typingUntil.filter { $0.value > Date() } ?? [:]
            }
        case .call:
            if let signal = message.call { calls.handle(signal, from: inbound.from) }
        case .groupOp:
            applyGroupOp(inbound)
        case .profile:
            applyProfile(inbound)
        case .groupProfile:
            applyGroupProfile(inbound)
        case .groupLeave:
            applyGroupLeave(inbound)
        case .reaction:
            applyReaction(inbound)
        case .edit:
            applyEdit(inbound)
        case .delete:
            applyDelete(inbound)
        case .pollVote:
            applyVote(inbound)
        case .locationUpdate:
            applyLocationUpdate(inbound)
        case .settings:
            applySettings(inbound, transport: transport, hops: hops)
        case .text, .image, .audio, .video, .file, .poll, .location:
            store(inbound, transport: transport, hops: hops)
        case .unknown:
            // A kind from a newer client: ignored, never shown as unreadable.
            break
        }
    }

    /// Conversation an inbound message belongs to.
    func conversationId(of inbound: InboundJSON) -> String {
        if let g = inbound.group { return Self.groupId(g) }
        if let ch = inbound.channel { return Self.channelId(ch) }
        return Self.directId(inbound.from)
    }

    func store(_ inbound: InboundJSON, transport: Transport, hops: Int?) {
        let message = inbound.message
        let conversationId: String
        let title: String
        let kind: ConversationKind
        let peer: String
        if let g = inbound.group {
            conversationId = Self.groupId(g)
            reloadContacts()
            title = groupNames[g] ?? groups.first { $0.id == g }?.name ?? "Groupe"
            kind = .group
            peer = g
        } else if let ch = inbound.channel {
            conversationId = Self.channelId(ch)
            title = "#" + ch
            kind = .channel
            peer = ch
        } else {
            conversationId = Self.directId(inbound.from)
            title = name(of: inbound.from)
            kind = .direct
            peer = inbound.from
        }
        if db.conversation(conversationId) == nil {
            db.save(ConversationRecord(id: conversationId, kind: kind, title: title, peer: peer, lastAt: message.ts, unread: 0, lastTransport: transport, previewSealed: nil))
        }
        guard !db.hasMessage(message.id) else { return }
        let seen = activeConversation == conversationId && UIApplication.shared.applicationState == .active
        let record = MessageRecord(
            id: message.id, conversationId: conversationId, sender: inbound.from, ts: message.ts, kind: message.kind.rawValue,
            bodySealed: SecretBox.shared.seal(message.json()), status: .delivered, transport: transport, hops: hops, relays: nil,
            replyTo: message.replyTo, mediaPath: nil, expireS: message.expireS.flatMap { $0 > 0 ? $0 : nil },
            expireAt: seen ? message.expireS.flatMap { $0 > 0 ? Clock.nowMs + Int64($0) * 1000 : nil } : nil)
        db.save(record)
        if record.expireAt != nil { scheduleExpiry() }
        typingUntil[conversationId] = nil
        let preview = Self.previewText(message)
        touch(conversationId, preview: kind == .direct ? preview : "\(name(of: inbound.from)) : \(preview)", transport: transport, incoming: !seen)

        if message.attachment != nil { fetchAttachment(of: message, recordId: record.id) }
        if kind == .direct {
            var receipt = AppMessage.make(.receipt)
            receipt.receipt = .init(of: [message.id], state: seen ? .read : .delivered, hops: hops)
            sendControl(receipt, to: inbound.from)
            // The session is open: my profile goes once to this contact (spec section 6).
            sendProfileIfNeeded(toContact: inbound.from)
        }
        if !seen, message.kind != .settings, kind != .channel {
            showMessageBanner(conversationId: conversationId, from: inbound.from, kind: kind, title: title, preview: preview)
        }
        if seen {
            Haptics.soft()
        } else if message.kind != .settings {
            let mentioned = core.map { message.mentions?.contains($0.fingerprintHex()) == true } ?? false
            Notifier.shared.post(
                conversationId: conversationId, title: title, sender: kind == .direct ? nil : name(of: inbound.from),
                body: preview, messageId: message.id, muted: db.conversation(conversationId)?.isMuted() == true && !mentioned)
        }
        messageVersion += 1
    }

    static func previewText(_ message: AppMessage) -> String {
        switch message.kind {
        case .text: message.text ?? ""
        case .image: "Photo"
        case .audio: "Note vocale"
        case .video: "Vidéo"
        case .file: "Document : " + (message.attachment?.name ?? "fichier")
        case .poll: "Sondage : " + (message.poll?.question ?? "")
        case .location: message.location?.liveUntil != nil ? "Position en direct" : "Position"
        case .settings: (message.settings?.expireS ?? 0) > 0 ? "Messages éphémères : " + timerLabel(message.settings?.expireS ?? 0) : "Messages éphémères désactivés"
        case .groupOp: "Groupe mis à jour"
        default: ""
        }
    }

    func touch(_ conversationId: String, preview: String, transport: Transport?, incoming: Bool) {
        guard var c = db.conversation(conversationId) else { return }
        c.lastAt = Clock.nowMs
        c.previewSealed = SecretBox.shared.seal(preview)
        if let transport { c.lastTransport = transport }
        if incoming { c.unread += 1 }
        db.save(c)
        reloadConversations()
        messageVersion += 1
    }


    // MARK: Contacts

    /// `relay1:` card, `relay1c:` compact link, `somarelay://add/...` link or `handle@node`.
    func addContact(from input: String) async throws -> ContactJSON {
        guard let core else { throw RelayCoreError.unknown("Pas d'identité.") }
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("somarelay://add/") { text = String(text.dropFirst("somarelay://add/".count)) }
        if text.hasPrefix("relay1:") {
            return try adopt(core.addContact(card: text))
        }
        if text.hasPrefix("relay1c:") {
            guard let compact = JSON.decode(CompactJSON.self, try core.parseCompactLink(text)) else { throw RelayCoreError.malformed("Lien illisible.") }
            // In mesh range: ask the phone directly. Else: the node directory.
            if let peer = nearby.first(where: { $0.compactLink.map { Self.fingerprint(ofCompact: $0, core: core) } == compact.fingerprint && $0.connected }) {
                mesh.sendControl(MeshControl(t: "card-req", card: myCard), to: peer.id)
                throw RelayCoreError.unknown("Demande envoyée par le mesh, la carte arrive.")
            }
            let nodeURL = compact.nodeUrl.flatMap(URL.init(string:))
            let mailbox = Self.mailbox(of: compact.fingerprint, core: core)
            let card = try await node.card(mailbox: mailbox, on: nodeURL)
            let added = try adopt(core.addContact(card: card))
            guard added.fingerprint == compact.fingerprint else {
                core.removeContact(fp: added.fingerprint)
                throw RelayCoreError.invalidCard("La carte ne correspond pas à l'empreinte du QR.")
            }
            return added
        }
        if text.contains("@") {
            let parts = text.split(separator: "@", maxSplits: 1).map(String.init)
            let nodeHost = parts.count > 1 ? parts[1] : ""
            let url = nodeHost.isEmpty ? nil : URL(string: nodeHost.hasPrefix("http") ? nodeHost : "https://" + nodeHost)
            let card = try await node.lookup(handle: parts[0], on: url)
            return try adopt(core.addContact(card: card))
        }
        throw RelayCoreError.malformed("Colle une carte relay1:, un lien relay1c: ou un pseudo@nœud.")
    }

    private func adopt(_ json: String) throws -> ContactJSON {
        guard let contact = JSON.decode(ContactJSON.self, json) else { throw RelayCoreError.malformed("Contact illisible.") }
        scheduleSave()
        reloadContacts()
        openDirect(contact.fingerprint)
        justAdded = contact
        Haptics.success()
        return contact
    }

    static func fingerprint(ofCompact link: String, core: RelayCoreAPI) -> String? {
        (try? core.parseCompactLink(link)).flatMap { JSON.decode(CompactJSON.self, $0)?.fingerprint }
    }

    /// First 16 bytes of SHA3-256("soma-relay/mailbox" || fp) in the real core; the mock uses SHA-256.
    static func mailbox(of fp: String, core: RelayCoreAPI) -> String {
        MailboxHash.mailbox(fp: fp, mock: core is MockRelayCore)
    }

    func requestCard(from peer: NearbyPeer) {
        mesh.sendControl(MeshControl(t: "card-req", card: myCard), to: peer.id)
        banner = "Demande envoyée à \(peer.name ?? peer.code)."
    }

    func setVerified(_ fp: String, _ verified: Bool) {
        core?.setVerified(fp: fp, verified: verified)
        scheduleSave()
        reloadContacts()
        if verified { Haptics.success() }
    }

    func rename(_ fp: String, to name: String) {
        // A local rename wins over the name in the contact's `profile` from now on.
        db.setValue(Data("1".utf8), for: "renamed:" + fp)
        core?.renameContact(fp: fp, name: name)
        scheduleSave()
        reloadContacts()
        if var c = db.conversation(Self.directId(fp)) {
            c.title = name
            db.save(c)
            reloadConversations()
        }
    }

    func removeContact(_ fp: String) {
        core?.removeContact(fp: fp)
        scheduleSave()
        deleteConversation(Self.directId(fp))
        reloadContacts()
    }

    func safetyWords(with fp: String) -> [String] {
        if demo { return DemoData.callWords }
        return core?.contactSafetyWords(fp: fp) ?? []
    }

    func safetyCode(with fp: String) -> String { core?.contactSafetyCode(fp: fp) ?? "" }

    // MARK: Groups and channels

    func createGroup(name: String, members: [String]) throws -> String {
        guard let core else { throw RelayCoreError.unknown("Pas d'identité.") }
        let gid = try core.createGroup(name: name, memberFps: members)
        scheduleSave()
        reloadContacts()
        let id = Self.groupId(gid)
        db.save(ConversationRecord(id: id, kind: .group, title: name, peer: gid, lastAt: Clock.nowMs, unread: 0, lastTransport: nil, previewSealed: SecretBox.shared.seal("Groupe créé")))
        reloadConversations()
        storeSystem("created", in: id, from: nil)
        sendProfileIfNeeded(toGroup: gid)
        return id
    }

    func joinChannel(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)).lowercased()
        guard !name.isEmpty else { return "" }
        core?.joinChannel(name: name, password: nil)
        scheduleSave()
        if !channels.contains(name) { channels.append(name) }
        UserDefaults.standard.set(channels, forKey: "channels")
        let id = Self.channelId(name)
        if db.conversation(id) == nil {
            db.save(ConversationRecord(id: id, kind: .channel, title: "#" + name, peer: name, lastAt: Clock.nowMs, unread: 0, lastTransport: .mesh, previewSealed: nil))
        }
        reloadConversations()
        return id
    }

    func leaveChannel(_ name: String) {
        core?.leaveChannel(name: name)
        channels.removeAll { $0 == name }
        UserDefaults.standard.set(channels, forKey: "channels")
        deleteConversation(Self.channelId(name))
    }

    // MARK: Identity

    func setDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != displayName else { return }
        core?.setDisplayName(trimmed)
        scheduleSave()
        restartMesh()
        broadcastProfile()
    }

    /// Publishes `handle` on the node directory. The node only accepts it from a mailbox that
    /// authenticated over `/v1/ws`, so the node link must be ready.
    func publishHandle() async throws {
        guard let core else { return }
        let handle = handle.lowercased()
        guard handle.count >= 3, handle.count <= 32,
            handle.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || "_.-".contains($0)) })
        else { throw RelayCoreError.malformed("Pseudo : 3 à 32 caractères parmi a-z, 0-9, _ . -") }
        guard nodeEnabled, nodeState == .ready else { throw RelayCoreError.unknown("Connecte-toi d'abord au nœud.") }
        (core as? MockRelayCore)?.setHandle(handle, node: nodeURL)
        // The card signed below carries the node URL last given to myCard.
        _ = core.myCard(nodeUrl: nodeURL, handle: handle)
        let entry = try core.signDirectoryEntry(handle: handle)
        scheduleSave()
        try await node.publish(handle: handle, card: entry.card, mailbox: core.mailboxHex(), signature: entry.sig)
        scheduleSave()
    }

    /// Sealed export of the engine state, for a backup the user keeps.
    func exportIdentity() -> URL? {
        guard let core else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("soma-relay-identite.relaykey")
        let payload = "relaystate1:" + core.exportState().base64url
        try? Data(payload.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Emergency wipe: keys, database, media, then back to onboarding.
    func wipe() {
        node.disconnect()
        mesh.stop()
        calls.endAll()
        locationSharer.stopAll()
        db.wipe()
        MediaStore.wipe()
        Notifier.shared.clearAll()
        SecretBox.destroyKey()
        for key in ["handle", "channels", "nodeURL"] { UserDefaults.standard.removeObject(forKey: key) }
        core = nil
        contacts = []
        groups = []
        conversations = []
        channels = []
        routes = [:]
        photos = [:]
        groupNames = [:]
        messageBanner = nil
        withAnimation(.smooth) { phase = .onboarding }
    }

    // MARK: Links

    func handle(url: URL) {
        let text = url.absoluteString
        if text.hasPrefix("somarelay://add/") {
            Task { _ = try? await addContact(from: text) }
            return
        }
        var payload: String?
        if let fragment = url.fragment, !fragment.isEmpty { payload = fragment }
        else if url.host() == "m" { payload = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        guard let payload, let env = Data(base64url: payload) else { return }
        handleEnvelope(env, via: .sms)
        banner = "Message SMS chiffré importé."
    }
}

// MARK: - Transport delegates

extension AppModel: MeshTransportDelegate {
    func mesh(_ mesh: MeshTransport, received frame: Data, fromLink link: UInt32, peerCode: String) {
        guard let meshRouter else { return }
        let result = meshRouter.onFrame(frame, fromLink: link, nowMs: Clock.nowMs)
        if !result.forward.isEmpty {
            mesh.broadcast(result.forward, excluding: result.excludeLink, jitter: true)
        }
        if let env = result.complete {
            handleEnvelope(env, via: .mesh, hops: result.hops, ingress: peerCode)
        }
    }

    func mesh(_ mesh: MeshTransport, control: MeshControl, from peer: String) {
        guard let core else { return }
        switch control.t {
        case "card-req":
            if let card = control.card, let json = try? core.addContact(card: card), let c = JSON.decode(ContactJSON.self, json) {
                scheduleSave()
                reloadContacts()
                openDirect(c.fingerprint)
                justAdded = c
            }
            mesh.sendControl(MeshControl(t: "card", card: myCard), to: peer)
        case "card":
            if let card = control.card, let json = try? core.addContact(card: card), let c = JSON.decode(ContactJSON.self, json) {
                scheduleSave()
                reloadContacts()
                openDirect(c.fingerprint)
                justAdded = c
                Haptics.success()
            }
        default:
            break
        }
    }

    func meshPeersChanged(_ mesh: MeshTransport) {
        let before = meshPeerCount
        meshPeerCount = mesh.connectedCount
        nearby = mesh.peers
        if meshPeerCount > before { flushOutbox(toNode: false, toMesh: true) }
    }
}

extension AppModel: NodeClientDelegate {
    func node(_ node: NodeClient, received envelope: Data) {
        handleEnvelope(envelope, via: .node)
        lastNodeEnvelope = Date()
    }

    func nodeStateChanged(_ node: NodeClient) {
        nodeState = node.state
        if node.isReady {
            flushOutbox(toNode: true, toMesh: false)
            node.queryPresence(contacts.map(\.mailbox))
        }
    }

    func node(_ node: NodeClient, presence online: Set<String>) {
        nodeOnline = online
    }
}

nonisolated extension DeliveryStatus: Comparable {
    static func < (a: DeliveryStatus, b: DeliveryStatus) -> Bool { AppDatabase.rank(a) < AppDatabase.rank(b) }
}
