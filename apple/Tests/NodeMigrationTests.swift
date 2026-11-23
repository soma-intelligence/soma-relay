import XCTest
@testable import SomaRelay

/// An update must not move an existing install to a node it never chose.
final class NodeMigrationTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "nodemigration-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testExistingIdentityWithoutStoredNodeGetsLegacyNode() {
        let url = AppConfig.initialNodeURL(defaults: defaults, hasIdentity: true)
        XCTAssertEqual(url, AppConfig.legacyNodeURL)
        XCTAssertEqual(defaults.string(forKey: "nodeURL"), AppConfig.legacyNodeURL, "written once")
    }

    func testFreshInstallKeepsDefaultAndWritesNothing() {
        let url = AppConfig.initialNodeURL(defaults: defaults, hasIdentity: false)
        XCTAssertEqual(url, AppConfig.defaultNodeURL)
        XCTAssertNil(defaults.string(forKey: "nodeURL"))
    }

    func testStoredChoiceIsNeverOverwritten() {
        defaults.set("https://mine.example", forKey: "nodeURL")
        XCTAssertEqual(AppConfig.initialNodeURL(defaults: defaults, hasIdentity: true), "https://mine.example")
        XCTAssertEqual(defaults.string(forKey: "nodeURL"), "https://mine.example")
    }

    func testMigrationRunsOnceAndSurvivesLaterDefaultChange() {
        _ = AppConfig.initialNodeURL(defaults: defaults, hasIdentity: true)
        defaults.set("https://later.example", forKey: "nodeURL")
        XCTAssertEqual(AppConfig.initialNodeURL(defaults: defaults, hasIdentity: true), "https://later.example")
    }

    func testSmsLinkBaseFollowsTheActiveNode() {
        XCTAssertEqual(AppConfig.smsLinkBase(nodeURL: "https://somarelay.westus2.cloudapp.azure.com"),
                       "https://somarelay.westus2.cloudapp.azure.com/m#")
        XCTAssertEqual(AppConfig.smsLinkBase(nodeURL: "https://mine.example/"), "https://mine.example/m#")
    }
}
