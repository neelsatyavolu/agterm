import XCTest
@testable import AgTermCore

final class ClosedTabsTests: XCTestCase {
    func testReopensNewestFirstWithoutTheEndedShell() throws {
        let closed = ClosedTabs()
        closed.push(SavedTab(cwd: "/a", scrollback: "", resume: nil))
        closed.push(SavedTab(cwd: "/b", scrollback: "x", resume: "command claude --resume 123", sessionID: "s1", tabID: "t1"))
        let last = try XCTUnwrap(closed.popLast())
        XCTAssertEqual(last.cwd, "/b")
        XCTAssertEqual(last.resume, "command claude --resume 123")
        XCTAssertEqual(last.tabID, "t1")
        XCTAssertNil(last.sessionID, "the closed tab's shell has ended")
        XCTAssertEqual(closed.popLast()?.cwd, "/a")
        XCTAssertNil(closed.popLast())
        XCTAssertTrue(closed.isEmpty)
    }

    func testTakesAnyTabAndNamesIt() throws {
        let closed = ClosedTabs()
        closed.push(SavedTab(cwd: "/Users/sam/code/web", scrollback: "", resume: "command claude --resume 123"))
        closed.push(SavedTab(cwd: "/Users/sam/code/api", scrollback: "", resume: "export PATH=x; command codex resume abc"))
        closed.push(SavedTab(cwd: "/Users/sam", scrollback: "", resume: nil, name: "Logs"))
        closed.push(SavedTab(cwd: "/tmp", scrollback: "", resume: nil))
        XCTAssertEqual(closed.tabs.map(ClosedTabs.title),
                       ["Claude Code — web", "Codex — api", "Logs — sam", "Shell — tmp"])
        XCTAssertEqual(closed.take(at: 1)?.cwd, "/Users/sam/code/api")
        XCTAssertEqual(closed.tabs.count, 3)
        XCTAssertNil(closed.take(at: 9))
    }

    func testKeepsOnlyTheNewest() {
        let closed = ClosedTabs()
        for i in 0..<(ClosedTabs.limit + 5) { closed.push(SavedTab(cwd: "/\(i)", scrollback: "", resume: nil)) }
        XCTAssertEqual(closed.tabs.count, ClosedTabs.limit)
        XCTAssertEqual(closed.tabs.first?.cwd, "/5")
    }
}
