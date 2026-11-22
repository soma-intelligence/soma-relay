import XCTest

/// Drives the running app from a step list, for simulator checks (mesh between two simulators,
/// web client, background, notifications). Steps come from `RELAY_STEPS` (one per line), passed
/// as `TEST_RUNNER_RELAY_STEPS` to xcodebuild. Not part of CI.
///
///   tap:<label>        tap the first element whose label or identifier is <label>
///   tapc:<text>        tap the first element whose label contains <text>
///   tapxy:<x>,<y>      tap at points from the top left of the window
///   type:<text>        type into the focused element (`\n` = return)
///   expect:<text>      wait until an element whose label contains <text> exists
///   wait:<seconds>     sleep
///   alert:<label>      tap a button in a system alert (springboard)
///   toggle:<label>     flip the switch labelled <label> (scrolls down to it)
///   swipeup, swipedown scroll the screen
///   home               go to the home screen
///   bundle:<id>        drive another app from here on (Safari, Files)
///   activate           bring the app to the foreground without relaunching it
///   dump:<path>        write the accessibility tree to <path> on the host
///   shot:<path>        save a screenshot as PNG to <path> on the host
///   sbdump:<path>      same for the springboard (system alerts)
final class RelayScriptUITests: XCTestCase {
    func testScript() throws {
        let steps = (ProcessInfo.processInfo.environment["RELAY_STEPS"] ?? "")
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var app = XCUIApplication(bundleIdentifier: "me.somalabs.relay")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.activate()
        for step in steps {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let op = parts[0]
            let arg = parts.count > 1 ? parts[1] : ""
            switch op {
            case "tap":
                let el = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@ OR identifier == %@", arg, arg)).firstMatch
                XCTAssertTrue(el.waitForExistence(timeout: 15), "missing \(arg)")
                el.tap()
            case "tapc":
                let el = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", arg)).firstMatch
                XCTAssertTrue(el.waitForExistence(timeout: 15), "missing \(arg)")
                el.tap()
            case "tapxy":
                let xy = arg.split(separator: ",").compactMap { Double($0) }
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: xy[0], dy: xy[1])).tap()
            case "type":
                app.typeText(arg.replacingOccurrences(of: "\\n", with: "\n"))
            case "expect":
                let el = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", arg)).firstMatch
                XCTAssertTrue(el.waitForExistence(timeout: 30), "never saw \(arg)")
            case "wait":
                Thread.sleep(forTimeInterval: Double(arg) ?? 1)
            case "alert":
                let button = springboard.buttons[arg]
                if button.waitForExistence(timeout: 8) { button.tap() }
            case "toggle":
                let cell = app.switches.matching(NSPredicate(format: "label == %@", arg)).firstMatch
                for _ in 0..<6 where !cell.isHittable { app.swipeUp() }
                XCTAssertTrue(cell.waitForExistence(timeout: 10), "missing \(arg)")
                let inner = cell.switches.firstMatch
                (inner.exists ? inner : cell).tap()
            case "swipeup":
                app.swipeUp()
            case "swipedown":
                app.swipeDown()
            case "home":
                XCUIDevice.shared.press(.home)
            case "bundle":
                app = XCUIApplication(bundleIdentifier: arg)
            case "activate":
                app.activate()
            case "dump":
                try? app.debugDescription.write(toFile: arg, atomically: true, encoding: .utf8)
            case "shot":
                try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: arg))
            case "sbdump":
                try? springboard.debugDescription.write(toFile: arg, atomically: true, encoding: .utf8)
            default:
                XCTFail("unknown step \(step)")
            }
        }
    }
}
