import XCTest

/// End to end against a real agterm and relay. Needs, in xcodebuild's environment:
///
/// - `TEST_RUNNER_PAIR_URL`: a fresh `agterm-remote://pair#…` link from agterm Settings (with
///   `&relay=` for a local relay). Used when the app isn't paired yet.
/// - `TEST_RUNNER_FAKE_CLAUDE`: path to a stand-in `claude` that shows a permission prompt and
///   prints `answered-<key>` (for the prompt test only).
///
/// Each test skips when what it needs is missing, so a plain `xcodebuild test` passes.
@MainActor
final class PairAndDriveTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    /// Runs a command in the Mac's first tab from the phone and waits for its output.
    func testRunCommandInTab() throws {
        let app = try openFirstTab()
        let marker = "phone-\(Int.random(in: 1000...9999))"
        reply(app, "echo \(marker)")
        // The echo's output (not just the typed command) is the marker on a line of its own.
        XCTAssertTrue(line(app, startingWith: marker).waitForExistence(timeout: 15), "the output never reached the phone")
        attach(app, "screen")
        app.buttons["esc"].tap()
    }

    /// Opens a new shell tab on the Mac from the phone, lands in it, and runs a command there.
    func testOpenNewTab() throws {
        let app = try openFirstTab()
        app.navigationBars.buttons.element(boundBy: 0).tap() // back to the tab list
        let before = app.buttons.matching(identifier: "tab-row").count
        app.buttons["New Tab"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Shell")).firstMatch.tap()
        app.buttons["Open"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen"].waitForExistence(timeout: 15), "the new tab never opened")
        attach(app, "new tab")
        let marker = "newtab-\(Int.random(in: 1000...9999))"
        reply(app, "echo \(marker)")
        XCTAssertTrue(line(app, startingWith: marker).waitForExistence(timeout: 15))
        reply(app, "exit") // closes the tab on the Mac again
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons.matching(identifier: "tab-row").element(boundBy: before - 1).waitForExistence(timeout: 10))
    }

    /// With the app closed, a permission prompt on the Mac arrives as a notification (through the
    /// deployed relay and APNs), and tapping it opens that tab. Needs `TEST_RUNNER_PUSH=1`, a
    /// pairing with a relay that can push, and either `TEST_RUNNER_FAKE_CLAUDE` (a real agterm)
    /// or `TEST_RUNNER_PUSH_TRIGGER`, text a stand-in Mac answers with a prompt 8 s later.
    func testPushWhenClosed() throws {
        try XCTSkipUnless(env["PUSH"] == "1", "Set TEST_RUNNER_PUSH=1 to run this test")
        let trigger = try XCTUnwrap(env["PUSH_TRIGGER"] ?? env["FAKE_CLAUDE"].map { "clear; sleep 8; \($0)" },
                                    "Set TEST_RUNNER_FAKE_CLAUDE or TEST_RUNNER_PUSH_TRIGGER")
        let app = try openFirstTab()
        sleep(3) // the push token reaches the relay on connect
        reply(app, trigger)
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Approval needed")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 60), "no notification arrived")
        let shot = XCTAttachment(screenshot: springboard.screenshot())
        shot.name = "notification"
        shot.lifetime = .keepAlways
        add(shot)
        banner.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let choice = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "don't ask again")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 15), "the tab with the prompt didn't open")
        attach(app, "opened from notification")
        choice.tap()
    }

    /// A stand-in Claude Code asks permission; the phone answers with the prompt card.
    func testAnswerPermissionPrompt() throws {
        let fake = try XCTUnwrap(env["FAKE_CLAUDE"], "Set TEST_RUNNER_FAKE_CLAUDE to run this test")
        let app = try openFirstTab()
        reply(app, "clear; \(fake)")
        let choice = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "don't ask again")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 15), "the prompt card never appeared")
        attach(app, "prompt")
        choice.tap()
        XCTAssertTrue(line(app, startingWith: "answered-2").waitForExistence(timeout: 10), "the answer never reached the agent")
        attach(app, "answered")
    }

    /// Real agents, driven only from the phone: start each one in the tab, ask it a question with
    /// the reply box, and wait for its answer on the live screen (and, for Claude Code and Codex,
    /// in Chat). Costs a few tokens per agent, so it runs only with `TEST_RUNNER_AGENTS`, a
    /// comma-separated list of commands such as `claude --model haiku,codex,grok`. A command can
    /// end in `|keys`, key bar presses that get past its first-run screens (`codex|enter`,
    /// `claude|down enter` for a folder trust prompt, `wait` for a 10 s pause).
    /// `TEST_RUNNER_AGENT_DIR` is the folder.
    func testRealAgents() throws {
        let commands = try XCTUnwrap(env["AGENTS"], "Set TEST_RUNNER_AGENTS to run this test")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let app = try openFirstTab()
        _ = quitAgent(app) // whatever an earlier run left behind
        reply(app, "cd \(env["AGENT_DIR"] ?? "~") && clear")
        var failures: [String] = []
        for command in commands {
            let quit = XCTContext.runActivity(named: command) { _ in
                if let problem = roundTrip(app, command) { failures.append("\(command): \(problem)") }
                return quitAgent(app)
            }
            // Anything typed next would go to the agent that wouldn't quit, not to a shell.
            guard quit else {
                failures.append("\(command): didn't quit with ^C; stopped before \(commands.drop { $0 != command }.dropFirst())")
                break
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// ^C twice in a row (most agents quit on the second), then checks a shell is back: only a
    /// shell turns `$((40+2))` into 42.
    private func quitAgent(_ app: XCUIApplication) -> Bool {
        for _ in 0..<2 {
            app.buttons["ctrlC"].tap()
            app.buttons["ctrlC"].tap()
            sleep(2)
        }
        let marker = "shell-\(Int.random(in: 100...999))-"
        reply(app, "clear; echo \(marker)$((40+2))")
        return line(app, startingWith: marker + "42").waitForExistence(timeout: 10)
    }

    /// nil when the agent answered on the phone; otherwise what went wrong.
    private func roundTrip(_ app: XCUIApplication, _ spec: String) -> String? {
        let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
        let command = parts[0]
        reply(app, command)
        sleep(15) // the agent's own start-up
        attach(app, "\(command) started")
        for key in parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : [] {
            // `wait` gives an agent that redraws after a dialog time to take input again.
            if key == "wait" { sleep(10) } else { app.buttons[key].tap() }
            sleep(3)
        }
        reply(app, "Reply with the word PONG spelled backwards and nothing else.")
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "gnop")).firstMatch
        guard answer.waitForExistence(timeout: 120) else {
            attach(app, "\(command) no answer")
            return "no answer on the live screen"
        }
        attach(app, "\(command) answered")
        let chat = app.buttons["Chat"]
        guard chat.exists else { return nil }
        chat.tap()
        defer { app.buttons["Screen"].tap() }
        let inChat = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "gnop")).firstMatch
        guard inChat.waitForExistence(timeout: 30) else {
            attach(app, "\(command) chat empty")
            return "answer missing from Chat"
        }
        attach(app, "\(command) chat")
        return nil
    }

    // MARK: Helpers

    private func openFirstTab() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        // The notifications question, once per install.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        let row = app.buttons.matching(identifier: "tab-row").firstMatch
        if !row.waitForExistence(timeout: 5) {
            let link = try XCTUnwrap(env["PAIR_URL"].flatMap(URL.init(string:)), "Not paired; set TEST_RUNNER_PAIR_URL")
            app.open(link)
            // iOS asks before opening a link in an app.
            let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
            if open.waitForExistence(timeout: 5) { open.tap() }
            XCTAssertTrue(row.waitForExistence(timeout: 20), "the Mac's tabs never arrived")
        }
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        attach(app, "tabs")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen"].waitForExistence(timeout: 10))
        return app
    }

    private func reply(_ app: XCUIApplication, _ text: String) {
        let field = app.textFields["reply"].exists ? app.textFields["reply"] : app.textViews["reply"]
        field.tap()
        field.typeText(text)
        app.buttons["send"].tap()
    }

    private func line(_ app: XCUIApplication, startingWith prefix: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
