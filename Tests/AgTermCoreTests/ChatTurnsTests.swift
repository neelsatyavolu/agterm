import XCTest
@testable import AgTermCore

/// Finished turns fold into a worked line, their answer and the files they changed.
final class ChatTurnsTests: XCTestCase {
    let rowsTests = ChatRowsTests()

    func user(_ id: String, _ text: String, state: String? = nil, ts: Int) -> MobileTimelineEntry {
        rowsTests.user(id, text, state: state, ts: ts)
    }

    func say(_ id: String, _ text: String, ts: Int) -> MobileTimelineEntry { rowsTests.text(id, "assistant", text, ts: ts) }

    func read(_ id: String, _ path: String, ts: Int) -> MobileTimelineEntry {
        rowsTests.tool(id, lead: "Read", name: "Read", subject: path, ts: ts)
    }

    func edit(_ id: String, _ path: String, ts: Int, status: String = "ok") -> MobileTimelineEntry {
        rowsTests.tool(id, lead: "Edited", name: "Edit", subject: path, status: status, body: "@@ -1 +1 @@\n-old\n+new\n",
                       additions: 1, deletions: 1, ts: ts)
    }

    func run(_ id: String, _ command: String, ts: Int, status: String = "ok") -> MobileTimelineEntry {
        rowsTests.tool(id, lead: "Ran", name: "Bash", subject: command, status: status, body: status == "ok" ? "ok" : "boom", ts: ts)
    }

    var turn: [MobileTimelineEntry] {
        [user("u1", "fix the redirect", ts: 1_000), rowsTests.text("t1", "thinking", "Tracing it", ts: 1_100),
         say("n1", "Reading the middleware first.", ts: 1_200), read("r1", "auth/session.ts", ts: 1_300),
         edit("e1", "auth/redirect.ts", ts: 2_000), run("c1", "npm test", ts: 3_000), edit("e2", "auth/redirect.ts", ts: 4_000),
         say("a1", "Fixed.", ts: 73_000)]
    }

    func testFinishedTurnFolds() {
        let rows = ChatRows.build(turn, working: false, live: false)
        XCTAssertEqual(rows.map(\.kindName), ["user", "worked", "assistant", "changes"])
        guard case .worked(let id, let steps, let ms) = rows[1] else { return XCTFail() }
        XCTAssertEqual(id, "worked:u1")
        XCTAssertEqual(ms, 72_000, "from your message to the answer")
        XCTAssertEqual(steps.map(\.kindName), ["thinking", "assistant", "tools", "edit", "commands", "edit"])
        XCTAssertEqual(ChatTurns.summary(steps), ["thought", "read 1", "edited 2", "ran 1"])
        XCTAssertEqual(rows[2], .assistant(id: "a1", text: "Fixed.", streaming: false))
        guard case .changes(_, let edits) = rows[3] else { return XCTFail() }
        XCTAssertEqual(edits.count, 1, "one file, edited twice")
        XCTAssertEqual(edits[0].additions, 2)
        XCTAssertEqual(edits[0].lines.count, 4)
    }

    func testLiveTurnStaysOpenEarlierTurnsFold() {
        let second = [user("u2", "now the logout", ts: 80_000), read("r2", "auth/logout.ts", ts: 81_000)]
        let rows = ChatRows.build(turn + second, working: true, live: true)
        XCTAssertEqual(rows.map(\.kindName), ["user", "worked", "assistant", "changes", "user", "tools"])
        XCTAssertEqual(ChatRows.build(turn + second, working: false, live: false).map(\.kindName),
                       ["user", "worked", "assistant", "changes", "user", "worked"])
    }

    func testTurnWithoutStepsIsLeftAlone() {
        let rows = ChatRows.build([user("u", "hi", ts: 1), say("a", "Hello", ts: 2)], working: false, live: false)
        XCTAssertEqual(rows.map(\.kindName), ["user", "assistant"])
    }

    func testInterruptedTurnKeepsItsMark() {
        let entries = [user("u", "go", ts: 1), read("r", "a.swift", ts: 2), MobileTimelineEntry(id: "i", kind: "interrupted", ts: 3)]
        let rows = ChatRows.build(entries, working: false, live: false)
        XCTAssertEqual(rows.map(\.kindName), ["user", "worked", "interrupted"])
    }

    func testFailuresAreCountedAndFailedEditsAreNotChanges() {
        let entries = [user("u", "go", ts: 1), run("c", "make", ts: 2, status: "error"), say("a", "Build fails.", ts: 3)]
        let rows = ChatRows.build(entries, working: false, live: false)
        guard case .worked(_, let steps, _) = rows[1] else { return XCTFail() }
        XCTAssertEqual(ChatTurns.summary(steps), ["ran 1", "1 failed"])
        XCTAssertFalse(rows.contains { $0.kindName == "changes" })
    }

    func testHistoryWithoutItsFirstMessage() {
        let rows = ChatRows.build([read("r", "a.swift", ts: 2), say("a", "Done", ts: 3)], working: false, live: false)
        XCTAssertEqual(rows.map(\.kindName), ["worked", "assistant"])
    }

    func testQueuedMessagesStayAtTheEnd() {
        let entries = turn + [user("q", "and then this", state: "queued", ts: 74_000)]
        let rows = ChatRows.build(entries, working: false, live: false)
        XCTAssertEqual(rows.last, .user(id: "q", text: "and then this", queued: true))
        XCTAssertEqual(rows.map(\.kindName), ["user", "worked", "assistant", "changes", "user"])
    }

    func testNestedRowsAreFoundForToggling() {
        let rows = ChatRows.build(turn, working: false, live: false)
        XCTAssertTrue(rows[1].holds("e1"))
        XCTAssertTrue(rows[1].holds("c1"), "a command folded into a run inside the worked line")
        XCTAssertTrue(rows[3].holds("file:e1"), "the changes list opens its own copy")
        XCTAssertFalse(rows[3].holds("e1"))
        XCTAssertFalse(rows[2].holds("e1"))
    }
}
