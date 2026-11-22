import Foundation
import UIKit
import UserNotifications

/// Local notifications (spec v1.1 section 2): one per incoming message when its conversation is
/// not on screen, grouped per conversation, with Reply and Mark as read. The remote push from the
/// node only says "Nouveau message"; the text always comes from here, after local decryption.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    nonisolated static let category = "message"
    nonisolated static let replyAction = "reply"
    nonisolated static let readAction = "read"

    weak var model: AppModel?
    private let center = UNUserNotificationCenter.current()

    func configure() {
        center.delegate = self
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyAction, title: "Répondre", options: [],
            textInputButtonTitle: "Envoyer", textInputPlaceholder: "Message chiffré")
        let read = UNNotificationAction(identifier: Self.readAction, title: "Marquer comme lu", options: [])
        let category = UNNotificationCategory(
            identifier: Self.category, actions: [reply, read], intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "Nouveau message", options: [])
        center.setNotificationCategories([category])
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Asks APNs for a token when notifications are already allowed (every launch).
    func registerForPush() {
        center.getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            guard ok else { return }
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Posts a notification for an incoming message. Previews off: "Nouveau message" only.
    func post(conversationId: String, title: String, sender: String?, body: String, messageId: String, muted: Bool, photoKey: String? = nil) {
        guard !muted, let model else { return }
        let content = UNMutableNotificationContent()
        if model.notificationPreviews {
            content.title = title
            content.body = sender.map { "\($0) : \(body)" } ?? body
            // The face as an attachment (no communication-notification entitlement needed).
            if let photoKey, let attachment = avatarAttachment(photoKey, messageId: messageId) { content.attachments = [attachment] }
        } else {
            content.title = "Soma Relay"
            content.body = "Nouveau message"
        }
        content.sound = .default
        content.threadIdentifier = conversationId
        content.categoryIdentifier = Self.category
        content.userInfo = ["conversation": conversationId, "message": messageId]
        content.badge = NSNumber(value: model.conversations.reduce(0) { $0 + $1.unread })
        center.add(UNNotificationRequest(identifier: messageId, content: content, trigger: nil))
        removeGenericPushes()
    }

    /// A copy of the avatar JPEG for the notification. The system moves it into its own store.
    private func avatarAttachment(_ key: String, messageId: String) -> UNNotificationAttachment? {
        guard let data = model?.db.value(for: "avatar:" + key) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-\(messageId).jpg")
        guard (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "avatar", url: url, options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"])
    }

    /// The node's "Nouveau message" pushes carry no thread: once the real ones are posted they go.
    private func removeGenericPushes() {
        center.getDeliveredNotifications { list in
            let ids = list.filter { $0.request.content.threadIdentifier.isEmpty }.map(\.request.identifier)
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func clear(_ conversationId: String) {
        center.getDeliveredNotifications { list in
            let ids = list.filter { $0.request.content.threadIdentifier == conversationId || $0.request.content.threadIdentifier.isEmpty }
                .map(\.request.identifier)
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func clearAll() {
        center.removeAllDeliveredNotifications()
        center.setBadgeCount(0) { _ in }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let thread = notification.request.content.threadIdentifier
        let show = await MainActor.run { () -> Bool in
            // The app is open: the node push is redundant, and the open chat needs no banner.
            guard !thread.isEmpty, let model = Notifier.shared.model else { return false }
            return model.activeConversation != thread
        }
        // The in-app glass banner already shows it: no second banner from the system.
        let inApp = await MainActor.run { Notifier.shared.model?.messageBanner?.conversationId == thread }
        if inApp { return [.list, .sound] }
        return show ? [.banner, .list, .sound] : []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let conversation = info["conversation"] as? String
        let messageId = info["message"] as? String
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            guard let model = Notifier.shared.model else { return }
            model.start()
            guard let conversation else { return }
            switch action {
            case Self.replyAction:
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    model.send(text: text, in: conversation, replyTo: nil)
                    model.markRead(conversation)
                }
            case Self.readAction:
                model.markRead(conversation)
            default:
                model.openRequest = ChatRoute(conversationId: conversation, focus: messageId)
            }
        }
        // Give the node a moment to take the reply before iOS suspends us.
        if action == Self.replyAction { try? await Task.sleep(for: .seconds(2)) }
    }
}
