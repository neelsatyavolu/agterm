import XCTest

/// Try the Demo, as App Review sees it: no Mac, no relay. Set `TEST_RUNNER_SHOTS` to a folder to
/// also save the App Store screenshots there (run it on the iPhone 17 Pro Max for 6.9").
@MainActor
final class DemoTests: XCTestCase {
    private let shots = ProcessInfo.processInfo.environment["SHOTS"]

    func testDemo() throws {
        let app = XCUIApplication()
        app.launch()
        let tryDemo = app.buttons["try-demo"]
        XCTAssertTrue(tryDemo.waitForExistence(timeout: 10), "the pairing screen has no demo button (already paired?)")
        tryDemo.tap()

        let rows = app.buttons.matching(identifier: "tab-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 4)
        save(app, "1-tabs")

        // Answer the sample approval: the edit runs and the agent reports back.
        rows.element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen"].waitForExistence(timeout: 5))
        save(app, "2-approval")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "1")).firstMatch.tap()
        XCTAssertTrue(text(app, containing: "passed 50 runs").waitForExistence(timeout: 6), "the approval never finished")

        // A reply asks once about third-party AI, then gets the demo's answer in Chat.
        app.buttons["Chat"].tap()
        save(app, "3-chat")
        let reply = app.textViews["reply"].exists ? app.textViews["reply"] : app.textFields["reply"]
        reply.tap()
        reply.typeText("Also cover the retry limit")
        app.buttons["send"].tap()
        let consent = app.alerts["Replies go to your Mac"]
        XCTAssertTrue(consent.waitForExistence(timeout: 3), "no third-party AI notice before the first reply")
        consent.buttons["Continue"].tap()
        XCTAssertTrue(text(app, containing: "This is the demo").waitForExistence(timeout: 6), "the reply got no answer")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        rows.element(boundBy: 1).tap()
        app.buttons["Screen"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5), "a working tab offers Stop")
        save(app, "4-working")

        // Exit Demo returns to pairing.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons["More"].tap()
        app.buttons["Exit Demo"].tap()
        XCTAssertTrue(tryDemo.waitForExistence(timeout: 5))
    }

    private func text(_ app: XCUIApplication, containing part: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? shot.pngRepresentation.write(to: URL(fileURLWithPath: shots).appendingPathComponent("\(name).png")) }
    }
}
