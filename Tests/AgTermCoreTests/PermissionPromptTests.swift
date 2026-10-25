import XCTest
@testable import AgTermCore

final class PermissionPromptTests: XCTestCase {
    func testClaudePermissionPrompt() {
        let screen = """
            ⏺ Bash(touch made.txt)
            ────────────────────────────────────────
             Bash command
             Create empty marker file
             Do you want to proceed?
             ❯ 1. Yes
               2. Yes, and always allow access to this folder
               3. No
             Esc to cancel · Tab to amend


            """
        XCTAssertTrue(PermissionPrompt.isVisible(screen.components(separatedBy: "\n")))
    }

    func testCodexChoice() {
        let screen = ["  Hooks need review", "› 1. Review hooks", "  2. Trust all and continue", "  enter confirm · esc skip"]
        XCTAssertTrue(PermissionPrompt.isVisible(screen))
    }

    func testBoxedPrompt() {
        XCTAssertTrue(PermissionPrompt.isVisible(["│ Do you want to make this edit? │", "│ ❯ 1. Yes │", "│   2. No │"]))
    }

    func testIdleInputIsNotAPrompt() {
        let screen = ["⏺ Done. Next steps:", "1. Run the tests", "2. Ship it?", "────", "❯ ", "────", "  ? for shortcuts"]
        XCTAssertFalse(PermissionPrompt.isVisible(screen))
        XCTAssertFalse(PermissionPrompt.isVisible(["❯ fix the bug in 1. the parser", "Esc to interrupt"]))
    }

    func testOnlyTheBottomCounts() {
        let old = ["Do you want to proceed?", "❯ 1. Yes", "  2. No", "Esc to cancel"]
        XCTAssertFalse(PermissionPrompt.isVisible(old + Array(repeating: "output", count: 20)))
    }

    func testAPromptMeansWaitingNotWorking() {
        var s = StatusSignals()
        s.titleActivity = .working
        s.lastTitleChange = Date()
        s.focused = true
        s.promptVisible = true
        XCTAssertEqual(StatusRules.status(s, now: Date()), .waiting)
        XCTAssertFalse(StatusRules.isWorking(s, now: Date()))
        s.promptVisible = false
        XCTAssertEqual(StatusRules.status(s, now: Date()), .working)
    }
}

final class AgentBusyTests: XCTestCase {
    func testBusyFlagOutranksAPausedSpinner() {
        var s = StatusSignals()
        let start = Date()
        s.titleActivity = .idle          // title shows idle between subagents
        s.agentBusy = true
        s.lastBusyChange = start
        XCTAssertTrue(StatusRules.isWorking(s, now: start.addingTimeInterval(30)))
        s.lastWorking = start.addingTimeInterval(30)
        s.lastSeen = start
        XCTAssertEqual(StatusRules.status(s, now: start.addingTimeInterval(30)), .working)
        s.agentBusy = false               // the whole turn is over
        XCTAssertEqual(StatusRules.status(s, now: start.addingTimeInterval(31)), .done)
    }

    func testInterruptStillStopsABusyAgent() {
        var s = StatusSignals()
        let start = Date()
        s.agentBusy = true
        s.lastBusyChange = start
        s.lastInterrupt = start.addingTimeInterval(2)
        XCTAssertFalse(StatusRules.isWorking(s, now: start.addingTimeInterval(3)))
    }
}
