import XCTest

/// Restore on a new phone (spec section 3): "Restaurer avec un passkey" on the welcome screen.
/// Fake passkey (`-uitest-passkey ok`: credential 16 x 0xC1, PRF 32 x 0x11 and 32 x 0x22) and a
/// local node driven by `apple/Tools/vault_test_node.py`, as in BackupUITests.
///
/// Seeding: the node accepts a vault PUT only from a mailbox that has authenticated over
/// `/v1/ws`, so the known identity is made by the app itself. It onboards with the fake
/// passkey, which backs the identity up; its safety words are read in Réglages; the emergency
/// wipe then removes everything on the phone (the node keeps the vault), which leaves the app
/// as a new phone would be. Restoring must bring the same words back.
///
/// Runner environment (xcodebuild `TEST_RUNNER_` prefix): RELAY_NODE_URL, RELAY_NODE_CTL.
final class RestoreUITests: XCTestCase {
    private var app: XCUIApplication!
    private var nodeURL = ""
    private var controlURL = ""

    private static let restored = "Identité restaurée. Utilise ce téléphone désormais."

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let node = env["RELAY_NODE_URL"], let control = env["RELAY_NODE_CTL"] else {
            throw XCTSkip("RELAY_NODE_URL and RELAY_NODE_CTL are not set (see apple/Tools/vault_test_node.py)")
        }
        nodeURL = node
        controlURL = control
        app = XCUIApplication()
    }

    // MARK: Tests

    func testRestoreBringsBackIdentity() throws {
        launchAtOnboarding(passkey: "ok")
        try control("start")
        onboard(name: "Eve")
        XCTAssertTrue(waitForStatus(containing: "Sauvegardé", timeout: 40), "seed backup: \(statusLabel)")
        let words = safetyWords()
        XCTAssertTrue(words.hasPrefix("Mots de sécurité : "), "words: \(words)")

        wipe()
        let restore = app.buttons["Restaurer avec un passkey"]
        XCTAssertTrue(restore.waitForExistence(timeout: 15), "no passkey restore on the welcome screen")
        XCTAssertTrue(app.buttons["Restaurer depuis un fichier"].exists, "the file import stays, second")
        restore.tap()

        XCTAssertTrue(app.staticTexts[Self.restored].waitForExistence(timeout: 20), "no restored banner")
        dismissSystemAlerts()
        let settings = app.buttons["settings.open"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "not in the app after restore")
        settings.tap()
        XCTAssertEqual(safetyWords(), words, "a different identity came back")

        // The lock is on (default delay) and the backup keeps going with the restored key.
        let lockSwitch = app.switches["Verrouiller Relay"]
        for _ in 0..<6 where !lockSwitch.isHittable { app.swipeUp() }
        XCTAssertEqual(lockSwitch.value as? String, "1", "the lock should be on after restore")
        XCTAssertTrue(waitForStatus(containing: "Sauvegardé", timeout: 40), "backup after restore: \(statusLabel)")
    }

    func testRestoreMissingVault() throws {
        launchAtOnboarding(passkey: "ok")
        try control("start")
        app.buttons["Restaurer avec un passkey"].tap()
        XCTAssertTrue(app.staticTexts["Aucune sauvegarde pour ce passkey"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Commencer"].isHittable, "still on onboarding, usable")
    }

    func testRestoreOffline() throws {
        launchAtOnboarding(passkey: "ok")
        try control("stop")
        app.buttons["Restaurer avec un passkey"].tap()
        XCTAssertTrue(app.staticTexts["Pas de réseau"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Commencer"].isHittable)
    }

    /// A passkey without PRF cannot open the backup; onboarding stays usable.
    func testRestoreWithoutPRF() throws {
        launchAtOnboarding(passkey: "noprf")
        try control("start")
        app.buttons["Restaurer avec un passkey"].tap()
        XCTAssertTrue(app.staticTexts["Ce passkey ne peut pas ouvrir la sauvegarde"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Commencer"].isHittable)
    }

    /// Cancelled sheet: no error text, nothing changes.
    func testRestoreCancelled() throws {
        launchAtOnboarding(passkey: "fail")
        app.buttons["Restaurer avec un passkey"].tap()
        sleep(1)
        XCTAssertTrue(app.buttons["Restaurer avec un passkey"].isHittable)
        XCTAssertTrue(app.buttons["Commencer"].isHittable)
        XCTAssertFalse(app.buttons["settings.open"].firstMatch.exists)
    }

    // MARK: Steps

    private func launchAtOnboarding(passkey: String) {
        app.launchArguments = ["-uitest-passkey", passkey, "-uitest-deviceauth", "ok", "-nodeURL", nodeURL, "-lockDelay", "-1"]
        app.launch()
        let start = app.buttons["Commencer"]
        if !start.waitForExistence(timeout: 6) { wipe() }
        XCTAssertTrue(start.waitForExistence(timeout: 15), "onboarding never showed")
    }

    /// Emergency wipe through Réglages.
    private func wipe() {
        let settings = app.buttons["settings.open"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "neither onboarding nor the tabs")
        settings.tap()
        let wipeButton = app.buttons["Effacement d'urgence"]
        for _ in 0..<12 where !wipeButton.isHittable { app.swipeUp() }
        wipeButton.tap()
        let confirm = app.buttons["Effacer clés, messages et médias"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
    }

    private func onboard(name: String) {
        app.buttons["Commencer"].tap()
        let field = app.textFields["Ton prénom"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.buttons["Créer mon identité"].tap()
        let create = app.buttons["Créer un passkey"]
        XCTAssertTrue(create.waitForExistence(timeout: 20), "no passkey step after the name")
        create.tap()
        let go = app.buttons["C'est parti"]
        XCTAssertTrue(go.waitForExistence(timeout: 20), "no card after the passkey step")
        go.tap()
        dismissSystemAlerts()
        let settings = app.buttons["settings.open"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
    }

    /// The safety words in Réglages ("Tes mots").
    private func safetyWords() -> String {
        let pills = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Mots de sécurité : ")).firstMatch
        for _ in 0..<6 where !pills.exists { app.swipeDown() }
        XCTAssertTrue(pills.waitForExistence(timeout: 10), "no safety words in Réglages")
        return pills.label
    }

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
                if app.buttons["settings.open"].firstMatch.exists, !app.navigationBars["Réglages"].exists {
                    app.buttons["settings.open"].firstMatch.tap()
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
        var request = URLRequest(url: URL(string: controlURL + "/" + action)!)
        request.timeoutInterval = 150
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var code = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 155)
        XCTAssertEqual(code, 200, "control \(action)")
    }
}
