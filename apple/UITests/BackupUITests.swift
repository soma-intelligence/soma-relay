import CryptoKit
import XCTest

/// Passkey backup to the node vault (spec section 3), with the fake passkey
/// (`-uitest-passkey ok|noprf`) and a local node driven by `apple/Tools/vault_test_node.py`.
///
/// Environment of the test runner (pass them to xcodebuild with the `TEST_RUNNER_` prefix):
///   RELAY_NODE_URL  the local node, for example http://127.0.0.1:8131 (given to the app as `-nodeURL`)
///   RELAY_NODE_CTL  its control server, for example http://127.0.0.1:8132 (/start, /stop)
/// Without them the tests are skipped.
///
/// Each test starts from onboarding (an identity left by an earlier test is wiped through
/// Réglages), then sets the node up: fresh, after the wipe, because the leftover identity
/// uploads its own vault as soon as it connects. Fresh because the fake passkey always gives
/// the same vault id, and the node gives a vault id to the first mailbox that writes it.
final class BackupUITests: XCTestCase {
    private var app: XCUIApplication!
    private var nodeURL = ""
    private var controlURL = ""

    /// `vault_id` of the fake credential (16 x 0xC1): hex(SHA-256("soma-relay vault id v1" || id)).
    private static let fakeVaultID: String = {
        var input = Data("soma-relay vault id v1".utf8)
        input.append(Data(repeating: 0xC1, count: 16))
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let node = env["RELAY_NODE_URL"], let control = env["RELAY_NODE_CTL"] else {
            throw XCTSkip("RELAY_NODE_URL and RELAY_NODE_CTL are not set (see apple/Tools/vault_test_node.py)")
        }
        nodeURL = node
        controlURL = control
        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "system alerts") { alert in
            for label in ["Autoriser", "Allow", "OK", "Ne pas autoriser", "Don't Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    // MARK: Tests

    func testSetupBacksUp() throws {
        launchAtOnboarding(passkey: "ok")
        try control("start")
        onboard(name: "Alice", protect: true)
        XCTAssertTrue(waitForStatus(containing: "Sauvegardé", timeout: 40), "status: \(statusLabel)")
        let blob = try fetchVault()
        XCTAssertEqual(blob.map { String(decoding: $0.prefix(4), as: UTF8.self) }, "RVB1")
    }

    func testNoPrfMeansLockOnly() throws {
        launchAtOnboarding(passkey: "noprf")
        try control("start")
        onboard(name: "Bruno", protect: true)
        XCTAssertTrue(waitForStatus(containing: "Votre gestionnaire ne prend pas en charge la sauvegarde", timeout: 15), "status: \(statusLabel)")
        XCTAssertNil(try fetchVault(), "no vault without PRF")
    }

    func testOfflineKeepsPending() throws {
        launchAtOnboarding(passkey: "ok")
        try control("stop")
        onboard(name: "Chloé", protect: true)
        XCTAssertTrue(waitForStatus(containing: "En attente du réseau", timeout: 20), "status: \(statusLabel)")
        XCTAssertFalse(statusLabel.contains("Sauvegardé"))

        // The node comes back; Relay goes to the background and returns.
        try control("start")
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(waitForStatus(containing: "Sauvegardé", timeout: 60), "status: \(statusLabel)")
        XCTAssertNotNil(try fetchVault())
    }

    // MARK: Steps

    private func launchAtOnboarding(passkey: String) {
        app.launchArguments = [
            "-uitest-passkey", passkey, "-uitest-deviceauth", "ok", "-nodeURL", nodeURL, "-lockDelay", "-1",
        ]
        app.launch()
        let start = app.buttons["Commencer"]
        if !start.waitForExistence(timeout: 6) {
            wipe()
        }
        XCTAssertTrue(start.waitForExistence(timeout: 15), "onboarding never showed")
    }

    /// Emergency wipe through Réglages, for an identity left by an earlier run.
    private func wipe() {
        let settings = app.tabBars.buttons["Réglages"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "neither onboarding nor the tabs")
        settings.tap()
        let wipeButton = app.buttons["Effacement d'urgence"]
        for _ in 0..<12 where !wipeButton.isHittable { app.swipeUp() }
        wipeButton.tap()
        let confirm = app.buttons["Effacer clés, messages et médias"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
    }

    private func onboard(name: String, protect: Bool) {
        app.buttons["Commencer"].tap()
        let field = app.textFields["Ton prénom"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.buttons["Créer mon identité"].tap()
        let create = app.buttons["Créer un passkey"]
        XCTAssertTrue(create.waitForExistence(timeout: 20), "no passkey step after the name")
        if protect { create.tap() } else { app.buttons["Plus tard"].tap() }
        let go = app.buttons["C'est parti"]
        XCTAssertTrue(go.waitForExistence(timeout: 20), "no card after the passkey step")
        go.tap()
        dismissSystemAlerts()
        let settings = app.tabBars.buttons["Réglages"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
    }

    /// Notifications, Bluetooth or local network permission alerts after onboarding.
    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { return }
            let button = ["Autoriser", "Allow", "OK", "Ne pas autoriser", "Don't Allow"]
                .map { alert.buttons[$0] }.first { $0.exists } ?? alert.buttons.firstMatch
            button.tap()
        }
    }

    private var statusElement: XCUIElement { app.descendants(matching: .any)["vault.status"] }

    private var statusLabel: String { statusElement.exists ? statusElement.label : "<missing>" }

    private func waitForStatus(containing text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !statusElement.exists || !statusElement.isHittable {
                if app.tabBars.buttons["Réglages"].exists, !app.navigationBars["Réglages"].exists {
                    app.tabBars.buttons["Réglages"].tap()
                }
                if !statusElement.exists { app.swipeUp() }
            }
            if statusElement.exists, statusElement.label.contains(text) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    // MARK: Node

    private func control(_ action: String) throws {
        let url = URL(string: controlURL + "/" + action)!
        let (_, code) = try get(url, timeout: 150)
        XCTAssertEqual(code, 200, "control \(action)")
    }

    /// The vault blob of the fake credential on the node, nil on 404.
    private func fetchVault() throws -> Data? {
        let (data, code) = try get(URL(string: nodeURL + "/v1/vault/" + Self.fakeVaultID)!, timeout: 10)
        if code == 404 { return nil }
        XCTAssertEqual(code, 200)
        return data
    }

    private func get(_ url: URL, timeout: TimeInterval) throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<(Data, Int), Error> = .failure(URLError(.timedOut))
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else {
                result = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 5)
        return try result.get()
    }
}
