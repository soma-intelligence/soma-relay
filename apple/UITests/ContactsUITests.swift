import XCTest

/// Contacts of the redesign (relay-screens 07 to 11) on the demo identity: my card row opens the
/// card screen, the segment switches to the scanner (field and nearby people), "Vérifier" opens
/// the safety words, the contact sheet has its quick actions and words, and the group info has its
/// actions and members.
final class ContactsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(screen: String) {
        app.launchArguments = ["-RelayDemoData", "YES", "-RelayDemoScreen", screen]
        app.launch()
    }

    func testMyCardAndScannerOnOneScreen() {
        launch(screen: "contacts")
        let card = app.descendants(matching: .any)["contacts.mycard"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "my card row on top")
        card.tap()
        XCTAssertTrue(app.buttons["Partager ma carte"].waitForExistence(timeout: 5), "one action on the card")
        XCTAssertFalse(app.staticTexts["Tes mots"].exists, "no personal safety words on the card")
        app.buttons["Scanner"].tap()
        XCTAssertTrue(app.textFields["add.field"].waitForExistence(timeout: 5), "pseudo or link field")
        XCTAssertTrue(app.staticTexts["À portée sur le mesh"].exists, "people in range")
        XCTAssertTrue(app.buttons["Ajouter Sami"].exists, "quick add chip")
        app.buttons["Ma carte"].tap()
        XCTAssertTrue(app.buttons["Partager ma carte"].waitForExistence(timeout: 5))
        app.buttons["Fermer"].firstMatch.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    func testVerifyFromContacts() {
        launch(screen: "contacts")
        XCTAssertTrue(app.staticTexts["À vérifier"].waitForExistence(timeout: 10))
        let verify = app.buttons["Vérifier Lou"]
        XCTAssertTrue(verify.exists)
        verify.tap()
        XCTAssertTrue(app.staticTexts["Vérifie avec Lou"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Les mots sont identiques"].exists)
        XCTAssertTrue(app.buttons["Ils sont différents"].exists)
        app.buttons["Les mots sont identiques"].tap()
        // Demo contacts live outside the core, so the verified flag does not reload here: check
        // that the sheet closes back onto Contacts.
        XCTAssertTrue(app.staticTexts["À vérifier"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Vérifie avec Lou"].exists, "sheet closed")
    }

    func testContactSheet() {
        launch(screen: "contact")
        XCTAssertTrue(app.staticTexts["Mots de sécurité"].waitForExistence(timeout: 10))
        for label in ["Écrire", "Appeler", "Vidéo"] {
            XCTAssertTrue(app.buttons[label].exists, "action \(label)")
        }
        XCTAssertTrue(app.staticTexts["Identiques"].exists, "verified state")
        XCTAssertTrue(app.staticTexts["Chemin actuel"].exists)
        XCTAssertTrue(app.buttons["Supprimer le contact"].exists)
    }

    func testGroupInfo() {
        launch(screen: "group-detail")
        XCTAssertTrue(app.staticTexts["Membres"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Ajouter"].exists)
        XCTAssertTrue(app.buttons["Rechercher"].exists)
        XCTAssertTrue(app.buttons["Quitter le groupe"].exists)
        app.buttons["Rechercher"].tap()
        XCTAssertTrue(app.textFields["Rechercher dans la conversation"].waitForExistence(timeout: 5), "search opens in the chat")
    }
}
