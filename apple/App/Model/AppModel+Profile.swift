import CryptoKit
import SwiftUI
import UIKit

/// A message that landed in another conversation than the open one (glass banner at the top).
struct MessageBanner: Identifiable, Equatable {
    let id = UUID()
    var conversationId: String
    /// Whose face to show: the sender for a direct chat, the group for a group.
    var photoKey: String?
    var title: String
    var preview: String
    var isGroup: Bool
}

/// Profile photos (spec section 6). 256 x 256 JPEG of at most 24 KiB, stored sealed in the kv
/// table like the engine state: `avatar:<owner>` holds the JPEG, `avatarHash:<owner>` its
/// lowercase hex SHA-256. The owner is a contact fingerprint, `me`, or `g:<group id>`.
nonisolated enum ProfilePhoto {
    static let side: CGFloat = 256
    static let maxBytes = 24 * 1024

    /// Square 256 px JPEG, quality lowered until it fits in 24 KiB.
    static func encode(_ image: UIImage) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: side, height: side)
        let scale = max(side / max(image.size.width, 1), side / max(image.size.height, 1))
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let square = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
        var quality: CGFloat = 0.85
        while quality > 0.05 {
            if let data = square.jpegData(compressionQuality: quality), data.count <= maxBytes { return data }
            quality -= 0.1
        }
        return square.jpegData(compressionQuality: 0.05).flatMap { $0.count <= maxBytes ? $0 : nil }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension AppModel {
    static let me = "me"
    static func groupPhotoKey(_ gid: String) -> String { "g:" + gid }

    // MARK: Local store

    func loadPhotos() {
        var loaded: [String: UIImage] = [:]
        for (owner, data) in db.values(prefix: "avatar:") {
            if let image = UIImage(data: data) { loaded[owner] = image }
        }
        photos = loaded
        var names: [String: String] = [:]
        for (gid, data) in db.values(prefix: "gname:") {
            if let name = String(data: data, encoding: .utf8) { names[gid] = name }
        }
        groupNames = names
    }

    func storePhoto(_ data: Data?, owner: String) {
        db.setValue(data, for: "avatar:" + owner)
        db.setValue(data.map { Data(ProfilePhoto.hash($0).utf8) }, for: "avatarHash:" + owner)
        withAnimation(.smooth) { photos[owner] = data.flatMap(UIImage.init(data:)) }
    }

    func photoHash(_ owner: String) -> String? {
        db.value(for: "avatarHash:" + owner).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The face of a fingerprint (nil = me).
    func photo(for fp: String?) -> UIImage? { photos[fp ?? Self.me] }

    func photo(of conversation: ConversationRecord) -> UIImage? {
        guard let peer = conversation.peer else { return nil }
        switch conversation.kind {
        case .direct: return photos[peer]
        case .group: return photos[Self.groupPhotoKey(peer)]
        case .channel: return nil
        }
    }

    private func renamedLocally(_ fp: String) -> Bool { db.value(for: "renamed:" + fp) != nil }

    // MARK: My profile

    /// New photo (or nil to remove it), then once to every contact and group.
    func setMyPhoto(_ image: UIImage?) {
        if let image {
            guard let data = ProfilePhoto.encode(image) else {
                banner = "Impossible de préparer cette photo."
                return
            }
            storePhoto(data, owner: Self.me)
        } else {
            storePhoto(nil, owner: Self.me)
        }
        Haptics.success()
        broadcastProfile()
    }

    private func myProfile() -> AppMessage.Profile {
        if let data = db.value(for: "avatar:" + Self.me) {
            return .init(name: displayName, avatar: .set(data.base64EncodedString()), avatarHash: ProfilePhoto.hash(data))
        }
        return .init(name: displayName, avatar: .remove)
    }

    /// What was sent last to a contact or group: name and photo hash.
    private var profileSignature: String {
        "\(displayName)|\(photoHash(Self.me) ?? "-")"
    }

    /// Sends my profile to every contact and every group it has not reached yet.
    func broadcastProfile() {
        guard !demo, core != nil else { return }
        for contact in contacts { sendProfileIfNeeded(toContact: contact.fingerprint) }
        for group in groups { sendProfileIfNeeded(toGroup: group.id) }
    }

    func sendProfileIfNeeded(toContact fp: String) {
        guard !demo, core != nil, contact(fp) != nil else { return }
        let key = "sentProfile:" + Self.directId(fp)
        let signature = profileSignature
        guard db.value(for: key).flatMap({ String(data: $0, encoding: .utf8) }) != signature else { return }
        var message = AppMessage.make(.profile)
        message.profile = myProfile()
        sendControl(message, to: fp)
        db.setValue(Data(signature.utf8), for: key)
    }

    func sendProfileIfNeeded(toGroup gid: String) {
        guard !demo, core != nil, groups.contains(where: { $0.id == gid }) else { return }
        let key = "sentProfile:" + Self.groupId(gid)
        let signature = profileSignature
        guard db.value(for: key).flatMap({ String(data: $0, encoding: .utf8) }) != signature else { return }
        var message = AppMessage.make(.profile)
        message.profile = myProfile()
        if sendGroupControl(message, to: gid) { db.setValue(Data(signature.utf8), for: key) }
    }

    // MARK: Receiving profiles

    func applyProfile(_ inbound: InboundJSON) {
        guard let profile = inbound.message.profile, inbound.from != core?.fingerprintHex() else { return }
        applyPhoto(profile, owner: inbound.from)
        if let name = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 64,
            let contact = contact(inbound.from), contact.name != name, !renamedLocally(inbound.from)
        {
            core?.renameContact(fp: inbound.from, name: name)
            scheduleSave()
            reloadContacts()
            if var c = db.conversation(Self.directId(inbound.from)) {
                c.title = name
                db.save(c)
                reloadConversations()
            }
        }
        messageVersion += 1
    }

    /// Stores the photo of a `profile` or `group-profile`. Returns what changed.
    @discardableResult func applyPhoto(_ profile: AppMessage.Profile, owner: String) -> PhotoChange {
        switch profile.avatar {
        case .keep:
            return .none
        case .remove:
            guard photos[owner] != nil || photoHash(owner) != nil else { return .none }
            storePhoto(nil, owner: owner)
            return .removed
        case .set(let base64):
            if let hash = profile.avatarHash?.lowercased(), hash == photoHash(owner) { return .none }
            // A little room over 24 KiB for other encoders; anything bigger is dropped.
            guard let data = Data(base64Encoded: base64), data.count <= 32 * 1024, UIImage(data: data) != nil else { return .none }
            guard ProfilePhoto.hash(data) != photoHash(owner) else { return .none }
            storePhoto(data, owner: owner)
            return .changed
        }
    }

    enum PhotoChange { case none, changed, removed }
}

// MARK: - Groups (spec section 6 and core-api.md Groups)

extension AppModel {
    func group(_ gid: String) -> GroupJSON? { groups.first { $0.id == gid } }

    func isAdmin(of gid: String) -> Bool {
        guard let me = core?.fingerprintHex() else { return false }
        return group(gid)?.admins.contains(me) == true
    }

    /// Display name of a group: the `group-profile` name, else the core's.
    func groupName(_ gid: String) -> String { groupNames[gid] ?? group(gid)?.name ?? "Groupe" }

    /// Sends the output of `group_encrypt`: sender-key distribution envelopes first (each to the
    /// mailbox in its tag), then the group envelope (kind 2) to every other member's mailbox and
    /// on the mesh. Returns whether the node took it and how many mesh links got it.
    @discardableResult func fanOutGroup(_ envs: [Data], group: GroupJSON, messageId: String?) -> (node: Bool, mesh: Int) {
        guard let core else { return (false, 0) }
        for env in envs.dropLast() { routeByTag(env, group: group) }
        guard let groupEnv = envs.last else { return (false, 0) }
        let meshSent = broadcastMesh(groupEnv)
        var nodeSent = false
        let me = core.fingerprintHex()
        for (index, member) in group.members.enumerated() where member != me {
            guard let mailbox = group.mailboxes?[safe: index] ?? contact(member)?.mailbox else { continue }
            if nodeEnabled, node.send(envelope: groupEnv, to: mailbox) { nodeSent = true } else {
                enqueue(groupEnv, mailbox: mailbox, peer: member, messageId: messageId)
            }
        }
        return (nodeSent, meshSent)
    }

    /// One envelope to the mailbox in its tag (key and op deliveries of `group_add`,
    /// `group_remove` and `group_encrypt`). Members who are not contacts go through the node.
    func routeByTag(_ env: Data, group: GroupJSON?) {
        guard let core, let tag = core.envelopeTagHex(env) else { return }
        if let member = contacts.first(where: { $0.mailbox == tag }) {
            _ = route(env, to: member, messageId: nil)
            return
        }
        let fp = group.flatMap { g in g.mailboxes?.firstIndex(of: tag).flatMap { g.members[safe: $0] } }
        if nodeEnabled, node.send(envelope: env, to: tag) { return }
        enqueue(env, mailbox: tag, peer: fp, messageId: nil)
    }

    /// A message into a group that is not stored as a bubble (profile, group-profile, leave).
    @discardableResult func sendGroupControl(_ message: AppMessage, to gid: String) -> Bool {
        guard let core, let group = group(gid) else { return false }
        do {
            let envs = try core.groupEncrypt(groupId: gid, appMessageJson: message.json())
            scheduleSave()
            fanOutGroup(envs, group: group, messageId: nil)
            return true
        } catch {
            return false
        }
    }

    // MARK: Ops from the core

    func applyGroupOp(_ inbound: InboundJSON) {
        reloadContacts()
        guard let op = inbound.message.groupOp else { return }
        let id = Self.groupId(op.id)
        let me = core?.fingerprintHex()
        let removed = op.event == "removed" || (op.members.map { members in me.map { !members.contains($0) } ?? false } ?? false)
        if removed {
            if db.conversation(id) != nil { storeSystem("removed", in: id, from: inbound.from) }
            return
        }
        if db.conversation(id) == nil {
            // Added to a group: it shows at the top at once, and my profile goes in once.
            let title = groupNames[op.id] ?? op.name ?? group(op.id)?.name ?? "Groupe"
            db.save(ConversationRecord(
                id: id, kind: .group, title: title, peer: op.id, lastAt: Clock.nowMs, unread: 0, lastTransport: nil,
                previewSealed: SecretBox.shared.seal("\(name(of: inbound.from)) t'a ajouté")))
            storeSystem("added-me", in: id, from: inbound.from)
            reloadConversations()
            sendProfileIfNeeded(toGroup: op.id)
        } else if var c = db.conversation(id), groupNames[op.id] == nil, let name = op.name, c.title != name {
            c.title = name
            db.save(c)
            reloadConversations()
        }
        messageVersion += 1
    }

    // MARK: Group profile

    /// Admin only: new photo (`.set` / `.remove`) and or name, sent with `group_encrypt`.
    func setGroupProfile(_ gid: String, photo: UIImage?? = nil, name: String? = nil) {
        guard isAdmin(of: gid) || demo else { return }
        var profile = AppMessage.Profile()
        var codes: [String] = []
        if let photo {
            if let image = photo {
                guard let data = ProfilePhoto.encode(image) else {
                    banner = "Impossible de préparer cette photo."
                    return
                }
                storePhoto(data, owner: Self.groupPhotoKey(gid))
                profile.avatar = .set(data.base64EncodedString())
                profile.avatarHash = ProfilePhoto.hash(data)
                codes.append("photo")
            } else {
                storePhoto(nil, owner: Self.groupPhotoKey(gid))
                profile.avatar = .remove
                codes.append("photo-removed")
            }
        }
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != groupName(gid) {
            setGroupName(name, gid: gid)
            profile.name = name
            codes.append("name:" + name)
        }
        guard !codes.isEmpty else { return }
        for code in codes { storeSystem(code, in: Self.groupId(gid), from: nil) }
        Haptics.success()
        guard !demo else { return }
        var message = AppMessage.make(.groupProfile)
        message.groupProfile = profile
        sendGroupControl(message, to: gid)
    }

    /// The whole group profile again, once, after adding a member (so the newcomer gets it).
    private func resendGroupProfile(_ gid: String) {
        let data = db.value(for: "avatar:" + Self.groupPhotoKey(gid))
        guard data != nil || groupNames[gid] != nil else { return }
        var message = AppMessage.make(.groupProfile)
        message.groupProfile = .init(
            name: groupNames[gid], avatar: data.map { .set($0.base64EncodedString()) } ?? .keep, avatarHash: data.map(ProfilePhoto.hash))
        sendGroupControl(message, to: gid)
    }

    private func setGroupName(_ name: String, gid: String) {
        groupNames[gid] = name
        db.setValue(Data(name.utf8), for: "gname:" + gid)
        if var c = db.conversation(Self.groupId(gid)) {
            c.title = name
            db.save(c)
            reloadConversations()
        }
    }

    func applyGroupProfile(_ inbound: InboundJSON) {
        guard let gid = inbound.group, let profile = inbound.message.groupProfile else { return }
        if group(gid) == nil { reloadContacts() }
        // Only an admin may change it.
        guard group(gid)?.admins.contains(inbound.from) == true else { return }
        var codes: [String] = []
        switch applyPhoto(profile, owner: Self.groupPhotoKey(gid)) {
        case .changed: codes.append("photo")
        case .removed: codes.append("photo-removed")
        case .none: break
        }
        if let name = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 64, name != groupName(gid) {
            setGroupName(name, gid: gid)
            codes.append("name:" + name)
        }
        for code in codes { storeSystem(code, in: Self.groupId(gid), from: inbound.from) }
        if !codes.isEmpty { messageVersion += 1 }
    }

    // MARK: Members

    /// Admin: adds members (`group_add` returns the key + log for the newcomer first, then the op
    /// for each other member, each routed by its tag), then the group profile once.
    func addMembers(_ fps: [String], to gid: String) {
        guard let core, isAdmin(of: gid) || demo else { return }
        var added: [String] = []
        for fp in fps where group(gid)?.members.contains(fp) == false {
            if demo {
                added.append(fp)
                continue
            }
            do {
                let before = group(gid)
                let envs = try core.groupAdd(groupId: gid, fp: fp)
                scheduleSave()
                reloadContacts()
                let after = group(gid) ?? before
                for env in envs { routeByTag(env, group: after) }
                added.append(fp)
            } catch {
                banner = error.message
            }
        }
        if demo, let i = groups.firstIndex(where: { $0.id == gid }) { groups[i].members += added }
        for fp in added { storeSystem("add:" + fp, in: Self.groupId(gid), from: nil) }
        guard !added.isEmpty else { return }
        Haptics.success()
        if !demo { resendGroupProfile(gid) }
    }

    /// Admin: removes a member (`group_remove` returns the op for the removed member, then the new
    /// key + log for each remaining one, each routed by its tag).
    func removeMember(_ fp: String, from gid: String, announce: Bool = true) {
        guard let core, isAdmin(of: gid) || demo, let before = group(gid), before.members.contains(fp) else { return }
        if demo {
            if let i = groups.firstIndex(where: { $0.id == gid }) { groups[i].members.removeAll { $0 == fp } }
        } else {
            do {
                let envs = try core.groupRemove(groupId: gid, fp: fp)
                scheduleSave()
                for env in envs { routeByTag(env, group: before) }
                reloadContacts()
            } catch {
                banner = error.message
                return
            }
        }
        if announce { storeSystem("remove:" + fp, in: Self.groupId(gid), from: nil) }
        Haptics.success()
    }

    /// `group-leave` first (the core's leave is local only), then forget the group.
    func leaveGroup(_ gid: String) {
        if !demo {
            sendGroupControl(AppMessage.make(.groupLeave), to: gid)
            core?.leaveGroup(groupId: gid)
            scheduleSave()
        }
        storePhoto(nil, owner: Self.groupPhotoKey(gid))
        db.setValue(nil, for: "gname:" + gid)
        db.setValue(nil, for: "sentProfile:" + Self.groupId(gid))
        groupNames[gid] = nil
        if demo { groups.removeAll { $0.id == gid } } else { reloadContacts() }
        deleteConversation(Self.groupId(gid))
        Haptics.success()
    }

    func applyGroupLeave(_ inbound: InboundJSON) {
        guard let gid = inbound.group else { return }
        storeSystem("leave", in: Self.groupId(gid), from: inbound.from)
        // An admin takes the member out, so the sender key rotates for everyone left.
        if isAdmin(of: gid) { removeMember(inbound.from, from: gid, announce: false) }
    }

    // MARK: System lines

    /// A centered line in a group ("Inès a changé la photo du groupe."): no bubble, no unread,
    /// no notification, the conversation does not move.
    func storeSystem(_ code: String, in conversationId: String, from sender: String?) {
        guard db.conversation(conversationId) != nil else { return }
        let message = AppMessage.make(.groupOp, text: code)
        db.save(MessageRecord(
            id: message.id, conversationId: conversationId, sender: sender, ts: message.ts, kind: message.kind.rawValue,
            bodySealed: SecretBox.shared.seal(message.json()), status: .read, transport: .local, hops: nil, relays: nil,
            replyTo: nil, mediaPath: nil))
        messageVersion += 1
    }

    /// The sentence of a system line, with today's names.
    func systemText(_ item: ChatItem) -> String {
        if item.message.kind == .settings {
            return Self.timerSentence(item.message.settings?.expireS ?? 0, by: item.isMine ? nil : name(of: item.sender))
        }
        let code = item.message.text ?? ""
        let who = item.isMine ? "Tu" : name(of: item.sender)
        let has = item.isMine ? "as" : "a"
        if code.hasPrefix("name:") { return "\(who) \(has) renommé le groupe « \(code.dropFirst(5)) »." }
        if code.hasPrefix("add:") { return "\(who) \(has) ajouté \(name(of: String(code.dropFirst(4))))." }
        if code.hasPrefix("remove:") { return "\(who) \(has) retiré \(name(of: String(code.dropFirst(7))))." }
        switch code {
        case "photo": return "\(who) \(has) changé la photo du groupe."
        case "photo-removed": return "\(who) \(has) retiré la photo du groupe."
        case "leave": return "\(who) \(has) quitté le groupe."
        case "created": return "Tu as créé le groupe."
        case "added-me": return "\(name(of: item.sender)) t'a ajouté au groupe."
        case "removed": return "Tu ne fais plus partie de ce groupe."
        default: return "Le groupe a changé."
        }
    }

    // MARK: In-app banner

    func showMessageBanner(conversationId: String, from fp: String, kind: ConversationKind, title: String, preview: String) {
        guard UIApplication.shared.applicationState == .active, activeConversation != conversationId,
            db.conversation(conversationId)?.isMuted() != true
        else { return }
        let isGroup = kind == .group
        let photoKey = isGroup ? db.conversation(conversationId)?.peer.map(Self.groupPhotoKey) : fp
        let text = notificationPreviews ? (isGroup ? "\(name(of: fp)) : \(preview)" : preview) : "Nouveau message"
        withAnimation(.spring(duration: 0.4, bounce: 0.25)) {
            messageBanner = MessageBanner(
                conversationId: conversationId, photoKey: photoKey, title: notificationPreviews ? title : "Soma Relay",
                preview: text, isGroup: isGroup)
        }
    }
}
