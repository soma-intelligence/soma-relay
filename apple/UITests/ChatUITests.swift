import XCTest

/// Chat of the redesign (relay-screens 02 to 05) on the demo identity: the identity capsule opens
/// the route detail, the composer says "Message" and shows the send button only with text, "+"
/// opens the Joindre sheet, and the call screen has its four labelled controls.
final class ChatUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(screen: String) {
        app.launchArguments = ["-RelayDemoData", "YES", "-RelayDemoScreen", screen]
        app.launch()
    }

    private var field: XCUIElement { app.textFields["Message"].firstMatch.exists ? app.textFields["Message"].firstMatch : app.textViews["Message"].firstMatch }

    func testComposerSendAppearsWithText() {
        launch(screen: "chat")
        let e2e = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Chiffré de bout en bout'")).firstMatch
        XCTAssertTrue(e2e.waitForExistence(timeout: 10), "encryption stated at the top of the thread")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "composer field labelled Message")
        XCTAssertFalse(app.buttons["Envoyer"].exists, "no send button while the field is empty")
        XCTAssertTrue(app.buttons["Note vocale"].exists)
        field.tap()
        field.typeText("Salut")
        XCTAssertTrue(app.buttons["Envoyer"].waitForExistence(timeout: 3), "send appears with text")
    }

    func testIdentityCapsuleOpensRoute() {
        launch(screen: "chat")
        let capsule = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Inès'")).firstMatch
        XCTAssertTrue(capsule.waitForExistence(timeout: 10))
        capsule.tap()
        XCTAssertTrue(app.staticTexts["Chemin des messages"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Mesh Bluetooth et Wi-Fi direct"].exists)
    }

    func testAttachSheetActions() {
        launch(screen: "chat")
        let plus = app.buttons["Joindre"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        plus.tap()
        XCTAssertTrue(app.staticTexts["Joindre"].waitForExistence(timeout: 5), "Joindre sheet")
        for label in ["Photos", "Fichier", "Position", "Sondage"] {
            XCTAssertTrue(app.buttons[label].exists, "action \(label)")
        }
        app.buttons["Sondage"].tap()
        XCTAssertTrue(app.navigationBars["Sondage"].waitForExistence(timeout: 5), "poll composer opens after the sheet")
    }

    func testCallControlsLabelled() {
        launch(screen: "call")
        XCTAssertTrue(app.staticTexts["Mots de l'appel"].waitForExistence(timeout: 10))
        for label in ["Haut-parleur", "Caméra", "Muet", "Raccrocher"] {
            XCTAssertTrue(app.buttons[label].exists, "control \(label)")
        }
    }
}
