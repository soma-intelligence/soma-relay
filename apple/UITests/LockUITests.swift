import Darwin
import XCTest

/// Lock screen (spec section 2). Identity: `-RelayDemoData YES` (demo conversation, in-memory
/// database, straight to the main tabs). Passkey: `-uitest-passkey ok|noprf|fail|nocred`.
/// `-uitest-lockseed` stores the unlock check value of the fake passkey (PRF output 32 x 0x11)
/// and its credential id, as Task 7 does after creating a real passkey. Lock settings are
/// UserDefaults keys passed as launch arguments (`-lockEnabled`, `-lockDelay`) so that no state
/// leaks from one test to the next. `-uitest-deviceauth ok|fail` replaces LAContext, except in
/// the Face ID test, which uses the simulator's enrolled face.
final class LockUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ arguments: [String]) {
        app.launchArguments = ["-RelayDemoData", "YES"] + arguments
        app.launch()
    }

    private var lockScreen: XCUIElement { app.otherElements["lock.screen"] }
    private var unlockButton: XCUIElement { app.buttons["Déverrouiller"] }
    private var fallbackButton: XCUIElement { app.buttons["Utiliser Face ID ou le code"] }
    private var conversationsTab: XCUIElement { app.tabBars.buttons["Conversations"] }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    func testLockAppearsAtLaunchWhenEnabled() {
        // Passkey cancelled at launch: the lock stays up.
        launch(["-uitest-passkey", "fail", "-uitest-lockseed", "-uitest-deviceauth", "fail", "-lockEnabled", "YES"])
        XCTAssertTrue(lockScreen.waitForExistence(timeout: 10))
        XCTAssertTrue(unlockButton.exists)
        // Taps do not reach the tabs behind the lock.
        let settingsTab = app.tabBars.buttons["Réglages"]
        if settingsTab.exists { settingsTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertFalse(app.switches["Verrouiller Relay"].exists)
        XCTAssertTrue(lockScreen.exists)
    }

    func testNoLockWhenDisabled() {
        launch(["-uitest-passkey", "fail", "-lockEnabled", "NO"])
        XCTAssertTrue(conversationsTab.waitForExistence(timeout: 10))
        XCTAssertFalse(lockScreen.exists)
    }

    func testUnlockWithPasskey() {
        // Device auth fails: only the passkey (PRF check) can open the lock.
        launch(["-uitest-passkey", "ok", "-uitest-lockseed", "-uitest-deviceauth", "fail", "-lockEnabled", "YES", "-lockDelay", "0"])
        XCTAssertTrue(waitGone(lockScreen), "the automatic assertion at launch should unlock")
        XCTAssertTrue(conversationsTab.isHittable)
        // The button does the same after a relock.
        relock()
        unlockButton.tap()
        XCTAssertTrue(waitGone(lockScreen))
    }

    func testFallbackWhenPasskeyFails() {
        launch(["-uitest-passkey", "fail", "-uitest-lockseed", "-uitest-deviceauth", "ok", "-lockEnabled", "YES"])
        XCTAssertTrue(fallbackButton.waitForExistence(timeout: 10))
        XCTAssertTrue(lockScreen.exists)
        fallbackButton.tap()
        XCTAssertTrue(waitGone(lockScreen))
    }

    func testFallbackWhenNoCredential() {
        launch(["-uitest-passkey", "nocred", "-uitest-lockseed", "-uitest-deviceauth", "fail", "-lockEnabled", "YES"])
        XCTAssertTrue(fallbackButton.waitForExistence(timeout: 10))
        // Device auth refused: still locked, the credential is kept, the button stays.
        fallbackButton.tap()
        XCTAssertTrue(lockScreen.exists)
        XCTAssertTrue(unlockButton.exists)
    }

    func testNoPRFFallsBackToDevice() {
        launch(["-uitest-passkey", "noprf", "-uitest-lockseed", "-uitest-deviceauth", "ok", "-lockEnabled", "YES", "-lockDelay", "0"])
        XCTAssertTrue(waitGone(lockScreen))
        relock()
        unlockButton.tap()
        XCTAssertTrue(waitGone(lockScreen))
    }

    /// Home, back: with delay 0 the lock screen is up again.
    private func relock() {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(lockScreen.waitForExistence(timeout: 10))
    }

    /// Real LAContext with the simulator's enrolled face (`xcrun simctl spawn <id> notifyutil`
    /// enrollment, run on the host before the test). The match is a Darwin notification posted
    /// from here: the runner lives inside the same simulator.
    func testFallbackWithSimulatedFaceID() throws {
        launch(["-uitest-passkey", "fail", "-uitest-lockseed", "-lockEnabled", "YES"])
        XCTAssertTrue(fallbackButton.waitForExistence(timeout: 10))
        fallbackButton.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["OK", "Autoriser", "Allow"] {
            let allow = springboard.buttons[label]
            if allow.waitForExistence(timeout: 2) { allow.tap(); break }
        }
        Thread.sleep(forTimeInterval: 1.5)
        let asksPasscode = springboard.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Passcode'")).firstMatch.exists
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Passcode'")).firstMatch.exists
        if asksPasscode {
            throw XCTSkip("Face ID is not enrolled on this simulator: run the simctl notifyutil enrollment first")
        }
        Self.postDarwinNotification("com.apple.BiometricKit_Sim.pearl.match")
        XCTAssertTrue(waitGone(lockScreen, timeout: 15))
    }

    func testRelockAfterDelay() {
        launch(["-uitest-passkey", "ok", "-uitest-lockseed", "-uitest-deviceauth", "fail", "-lockEnabled", "YES", "-lockDelay", "0"])
        XCTAssertTrue(waitGone(lockScreen))
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(lockScreen.waitForExistence(timeout: 10))
        // No automatic assertion after a relock: the person taps.
        XCTAssertTrue(unlockButton.exists)
        unlockButton.tap()
        XCTAssertTrue(waitGone(lockScreen))
    }

    func testNoRelockBeforeDelay() {
        launch(["-uitest-passkey", "ok", "-uitest-lockseed", "-uitest-deviceauth", "fail", "-lockEnabled", "YES", "-lockDelay", "3600"])
        XCTAssertTrue(waitGone(lockScreen))
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(conversationsTab.waitForExistence(timeout: 10))
        XCTAssertTrue(waitGone(lockScreen, timeout: 3))
    }

    /// The lock window sits above sheets: an open sheet (export, with the keyboard up) is covered
    /// after a relock and cannot be used.
    func testLockCoversOpenSheet() {
        launch(["-uitest-passkey", "ok", "-uitest-lockseed", "-uitest-deviceauth", "fail", "-lockEnabled", "YES", "-lockDelay", "0"])
        XCTAssertTrue(waitGone(lockScreen))
        app.tabBars.buttons["Réglages"].tap()
        let export = app.buttons["Exporter mon identité"]
        for _ in 0..<8 where !export.isHittable { app.swipeUp() }
        export.tap()
        let cancel = app.buttons["Annuler"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(cancel.isHittable)
        relock()
        XCTAssertTrue(unlockButton.isHittable)
        XCTAssertFalse(cancel.isHittable, "the sheet must be under the lock")
        // Not even in the accessibility tree (VoiceOver cannot reach it).
        XCTAssertFalse(cancel.exists, "the sheet must be hidden from accessibility while locked")
        XCTAssertFalse(app.textFields.matching(NSPredicate(format: "label == 'Phrase de passe'")).firstMatch.exists
            || app.secureTextFields["Phrase de passe"].exists)
        unlockButton.tap()
        XCTAssertTrue(waitGone(lockScreen))
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the sheet is back in the accessibility tree")
        XCTAssertTrue(cancel.isHittable, "the sheet is still there after the unlock")
    }

    /// Setting the clock back must not skip the relock: the wall clock goes back 2 h while the
    /// delay is 1 h, so the elapsed wall time is negative.
    func testRelockWhenClockGoesBack() {
        launch(["-uitest-passkey", "ok", "-uitest-lockseed", "-uitest-deviceauth", "fail", "-lockEnabled", "YES", "-lockDelay", "3600", "-uitest-clockskew", "-7200"])
        XCTAssertTrue(waitGone(lockScreen))
        relock()
    }

    func testEnableAndDisableInSettings() {
        launch(["-uitest-passkey", "fail", "-uitest-deviceauth", "ok", "-lockEnabled", "NO"])
        openSettingsToggle()
        let toggle = lockToggle
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Verrouiller après"].waitForExistence(timeout: 5) || app.buttons["Verrouiller après"].exists)
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.switches.firstMatch.tap()
        let off = expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [off], timeout: 5), .completed)
    }

    func testEnableRefusedWithoutUnlock() {
        launch(["-uitest-passkey", "fail", "-uitest-deviceauth", "fail", "-lockEnabled", "NO"])
        openSettingsToggle()
        lockToggle.switches.firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(lockToggle.value as? String, "0")
    }

    func testWipeClearsLock() {
        // Enable from Settings (persists lockEnabled), seed the check value, then wipe.
        launch(["-uitest-passkey", "ok", "-uitest-lockseed", "-uitest-deviceauth", "ok"])
        if lockScreen.waitForExistence(timeout: 3) { XCTAssertTrue(waitGone(lockScreen)) }
        openSettingsToggle()
        if lockToggle.value as? String == "0" { lockToggle.switches.firstMatch.tap() }
        let on = expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: lockToggle)
        XCTAssertEqual(XCTWaiter.wait(for: [on], timeout: 5), .completed)
        let wipe = app.buttons["Effacement d'urgence"]
        for _ in 0..<8 where !wipe.isHittable { app.swipeUp() }
        wipe.tap()
        let confirm = app.buttons["Effacer clés, messages et médias"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["Restaurer avec un passkey"].waitForExistence(timeout: 10), "back to onboarding")
        XCTAssertFalse(lockScreen.exists)

        // Relaunch: lockEnabled is gone (no lock screen).
        app.terminate()
        launch(["-uitest-passkey", "ok", "-uitest-deviceauth", "fail"])
        XCTAssertTrue(conversationsTab.waitForExistence(timeout: 10))
        XCTAssertFalse(lockScreen.exists)

        // Relaunch with the lock forced on and no seed: the check value is gone, so the passkey
        // is not used and refused device auth keeps the lock.
        app.terminate()
        launch(["-uitest-passkey", "ok", "-uitest-deviceauth", "fail", "-lockEnabled", "YES"])
        XCTAssertTrue(lockScreen.waitForExistence(timeout: 10))
        unlockButton.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(lockScreen.exists)
    }

    /// `notify_post` is not in the iOS Darwin module overlay; look it up in libsystem_notify.
    private static func postDarwinNotification(_ name: String) {
        typealias NotifyPost = @convention(c) (UnsafePointer<CChar>) -> UInt32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "notify_post") else {
            XCTFail("notify_post missing")
            return
        }
        _ = unsafeBitCast(symbol, to: NotifyPost.self)(name)
    }

    private var lockToggle: XCUIElement { app.switches["Verrouiller Relay"] }

    private func openSettingsToggle() {
        XCTAssertTrue(app.tabBars.buttons["Réglages"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Réglages"].tap()
        for _ in 0..<8 where !lockToggle.isHittable { app.swipeUp() }
        XCTAssertTrue(lockToggle.waitForExistence(timeout: 5))
    }
}
