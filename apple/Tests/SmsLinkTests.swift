import XCTest
@testable import SomaRelay

final class SmsLinkTests: XCTestCase {
    func testSmsLinkBaseFollowsTheActiveNode() {
        XCTAssertEqual(AppConfig.smsLinkBase(nodeURL: "https://hushrelay.westus2.cloudapp.azure.com"),
                       "https://hushrelay.westus2.cloudapp.azure.com/m#")
        XCTAssertEqual(AppConfig.smsLinkBase(nodeURL: "https://mine.example/"), "https://mine.example/m#")
    }
}
