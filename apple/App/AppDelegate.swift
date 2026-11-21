import BackgroundTasks
import UIKit

/// Owns the model so that pushes, notification actions and background refresh reach it even when
/// iOS launches the app without showing it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static let refreshTask = "me.somalabs.relay.refresh"

    let model = AppModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Notifier.shared.model = model
        Notifier.shared.configure()
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTask, using: .main) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            MainActor.assumeIsolated { AppDelegate.runRefresh(task) }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.setPushToken(deviceToken.hex)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No Push capability (simulator without APNs, free team): the app still works, it only
        // fetches when opened.
    }

    /// Silent wake from the node: open the mailbox, decrypt, post local notifications.
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        let got = await model.drainMailbox(timeout: 20)
        return got ? .newData : .noData
    }

    @MainActor private static func runRefresh(_ task: BGAppRefreshTask) {
        guard let delegate = UIApplication.shared.delegate as? AppDelegate else {
            task.setTaskCompleted(success: false)
            return
        }
        let work = Task { @MainActor in
            let got = await delegate.model.drainMailbox(timeout: 25)
            _ = got
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
        scheduleRefresh()
    }

    /// Asks iOS for a refresh in about 15 minutes (it decides when).
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
