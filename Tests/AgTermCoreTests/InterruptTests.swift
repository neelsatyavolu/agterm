import XCTest
@testable import AgTermCore

final class InterruptTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 10_000)

    private func spinner(changedAgo: TimeInterval) -> StatusSignals {
        var s = StatusSignals()
        s.titleActivity = .working
        s.lastTitleChange = now.addingTimeInterval(-changedAgo)
        s.focused = true
        return s
    }

    func testAnimatingSpinnerIsWorking() {
        XCTAssertEqual(StatusRules.status(spinner(changedAgo: 0.9), now: now), .working)
    }

    func testSpinnerThatStoppedAnimatingIsNotWorking() {
        // Claude killed mid-turn, or a tool still running after Esc: the glyph stays but stops changing.
        XCTAssertEqual(StatusRules.status(spinner(changedAgo: 5), now: now), .idle)
    }

    func testInterruptEndsWorkingImmediately() {
        var s = spinner(changedAgo: 0.5)
        s.lastInterrupt = now.addingTimeInterval(-0.2)
        XCTAssertEqual(StatusRules.status(s, now: now), .idle)
    }

    func testWorkAfterTheInterruptCountsAgain() {
        var s = spinner(changedAgo: 0.1)
        s.lastInterrupt = now.addingTimeInterval(-2)
        XCTAssertEqual(StatusRules.status(s, now: now), .working)
    }

    func testOutputBasedAgentsStopOnInterruptToo() {
        var s = StatusSignals()
        s.lastInput = now.addingTimeInterval(-10)
        s.lastOutput = now.addingTimeInterval(-0.3)
        s.lastInterrupt = now.addingTimeInterval(-0.1)
        XCTAssertEqual(StatusRules.status(s, now: now), .idle)
    }

    func testAnInterruptedTabIsNotDone() {
        // Stopped from the phone while the tab was in the background: not "finished while away".
        var s = StatusSignals()
        s.titleActivity = .idle
        s.lastSeen = now.addingTimeInterval(-60)
        s.lastWorking = now.addingTimeInterval(-3)
        s.lastInterrupt = now.addingTimeInterval(-2.9)
        XCTAssertEqual(StatusRules.status(s, now: now), .idle)
    }

    func testOnlyBareEscapeAndControlCAreInterrupts() {
        XCTAssertTrue(StatusRules.isInterrupt([0x1b]))
        XCTAssertTrue(StatusRules.isInterrupt([0x03]))
        XCTAssertFalse(StatusRules.isInterrupt([0x1b, 0x5b, 0x41]), "arrow keys start with ESC")
        XCTAssertFalse(StatusRules.isInterrupt(Array("hi".utf8)))
    }
}
