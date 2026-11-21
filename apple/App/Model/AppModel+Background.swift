import Foundation
import UIKit

/// Push registration with the node and the short background windows iOS gives us (silent push,
/// BGAppRefreshTask): connect, take what the mailbox holds, decrypt, notify, save, done.
extension AppModel {
    static var pushEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "prod"
        #endif
    }

    func setPushToken(_ hex: String) {
        guard !demo else { return }
        node.setPushToken(hex, env: Self.pushEnvironment)
    }

    /// Returns true when at least one envelope arrived. Waits for the node, then until the
    /// mailbox has been quiet for 2 s, `timeout` seconds at most.
    func drainMailbox(timeout: TimeInterval) async -> Bool {
        start()
        guard core != nil, nodeEnabled, !demo else { return false }
        let began = Date()
        let before = lastNodeEnvelope
        if !node.isReady { node.connect() }
        while Date().timeIntervalSince(began) < timeout, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(400))
            guard node.isReady else { continue }
            let quietSince = max(lastNodeEnvelope, began.addingTimeInterval(1.5))
            if Date().timeIntervalSince(quietSince) > 2 { break }
        }
        saveNow()
        return lastNodeEnvelope > before
    }

    func didBecomeActive() {
        guard phase == .ready else { return }
        if nodeEnabled, !node.isReady, !demo { node.connect() }
        runExpiry()
        if let active = activeConversation { markRead(active) }
    }

    func didEnterBackground() {
        saveNow()
        AppDelegate.scheduleRefresh()
    }
}
