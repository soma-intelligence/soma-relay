import Observation
import SwiftUI
import UIKit

/// What the lock window draws; updated from `RootView` on every change.
@Observable
final class LockWindowState {
    var coverOnly = false
    var sceneActive = true
}

/// Puts `LockView` in its own `UIWindow` at `.alert + 1`, above the app window and everything
/// it presents (sheets, full-screen covers, dialogs, CallView). The app windows stay untouched
/// beneath it. Shown when `visible`; hidden otherwise.
struct LockWindowHost: UIViewRepresentable {
    let lock: LockController
    let visible: Bool
    let coverOnly: Bool
    let sceneActive: Bool

    func makeUIView(context: Context) -> LockWindowAnchor {
        let anchor = LockWindowAnchor(lock: lock)
        anchor.isUserInteractionEnabled = false
        return anchor
    }

    func updateUIView(_ anchor: LockWindowAnchor, context: Context) {
        anchor.update(visible: visible, coverOnly: coverOnly, sceneActive: sceneActive)
    }

    static func dismantleUIView(_ anchor: LockWindowAnchor, coordinator: ()) {
        anchor.tearDown()
    }
}

/// Invisible view in the app window; it finds the window scene and owns the lock window.
final class LockWindowAnchor: UIView {
    private let lock: LockController
    private let state = LockWindowState()
    private var lockWindow: UIWindow?
    private var visible = false

    init(lock: LockController) {
        self.lock = lock
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    func update(visible: Bool, coverOnly: Bool, sceneActive: Bool) {
        state.coverOnly = coverOnly
        state.sceneActive = sceneActive
        self.visible = visible
        apply()
    }

    func tearDown() {
        lockWindow?.isHidden = true
        lockWindow = nil
    }

    private func apply() {
        if visible {
            guard let scene = window?.windowScene else { return }
            let lockWindow = self.lockWindow ?? makeWindow(scene: scene)
            self.lockWindow = lockWindow
            guard lockWindow.isHidden else { return }
            // Shown at once (no fade): the app switcher snapshot is taken right after backgrounding.
            lockWindow.alpha = 1
            // The keyboard window sits above `.alert + 1`; close it so typed text is not left in view.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            lockWindow.makeKeyAndVisible()
        } else if let lockWindow, !lockWindow.isHidden {
            let appWindow = window
            UIView.animate(withDuration: 0.25, animations: { lockWindow.alpha = 0 }) { _ in
                // A new lock may have been asked for during the fade.
                guard !self.visible else {
                    lockWindow.alpha = 1
                    return
                }
                lockWindow.isHidden = true
                appWindow?.makeKey()
            }
        }
    }

    private func makeWindow(scene: UIWindowScene) -> UIWindow {
        let lockWindow = UIWindow(windowScene: scene)
        lockWindow.windowLevel = .alert + 1
        let host = UIHostingController(rootView: LockWindowRoot(lock: lock, state: state))
        host.view.backgroundColor = .clear
        lockWindow.rootViewController = host
        lockWindow.isHidden = true
        return lockWindow
    }
}

private struct LockWindowRoot: View {
    let lock: LockController
    let state: LockWindowState

    var body: some View {
        LockView(lock: lock, coverOnly: state.coverOnly, sceneActive: state.sceneActive)
            .tint(Theme.mesh)
    }
}
