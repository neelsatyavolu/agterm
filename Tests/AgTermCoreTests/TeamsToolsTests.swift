import XCTest
@testable import AgTermCore

/// Ported from agmux `src-tauri/src/teams/scan/tools.rs` tests.
final class TeamsToolsTests: XCTestCase {
    func testClassifiesAllThreeProviderVocabularies() {
        let cases: [(String, ToolKind)] = [
            ("Bash", .bash), ("Edit", .edit), ("Read", .read), ("Grep", .search), ("WebSearch", .web), ("Task", .agent),
            ("exec_command", .bash), ("apply_patch", .edit), ("spawn_agent", .agent),
            ("run_terminal_command", .bash), ("search_replace", .edit), ("read_file", .read), ("list_dir", .search),
            ("spawn_subagent", .agent),
        ]
        for (name, kind) in cases { XCTAssertEqual(TeamsTools.classify(name), kind, name) }
    }

    func testMCPToolsAreTheirOwnKind() {
        XCTAssertEqual(TeamsTools.classify("mcp__agmux-memory__memory_add"), .mcp)
        XCTAssertEqual(TeamsTools.classify("mcp__whatever"), .mcp)
    }

    func testUnknownNamesFallToOtherSoKindsResumToTheTotal() {
        XCTAssertEqual(TeamsTools.classify("TodoWrite"), .other)
        XCTAssertEqual(TeamsTools.classify("update_plan"), .other)
        let t = ["Bash", "Edit", "TodoWrite", "mcp__x__y", "Read"].reduce(ToolTally()) { $0.counting(TeamsTools.classify($1)) }
        XCTAssertEqual(t.calls, 5, "every call lands in exactly one kind")
    }

    func testEmptyTextCountsAsZeroLines() {
        XCTAssertEqual(TeamsTools.lineCount(""), 0)
        XCTAssertEqual(TeamsTools.lineCount("one"), 1)
        XCTAssertEqual(TeamsTools.lineCount("one\ntwo"), 2)
        XCTAssertEqual(TeamsTools.lineCount("trailing\n"), 1)
    }

    func testUnifiedDiffSkipsFileHeaders() {
        let diff = "--- a/src/main.rs\n+++ b/src/main.rs\n@@ -1,3 +1,4 @@\n context\n-gone\n+added one\n+added two\n"
        let lines = TeamsTools.unifiedDiffLines(diff)
        XCTAssertEqual([lines.added, lines.removed], [2, 1])
    }

    func testReplacementCountsBothSides() {
        let edit = TeamsTools.replacementLines(old: "a\nb", new: "a\nb\nc")
        XCTAssertEqual([edit.added, edit.removed], [3, 2])
        // A pure insertion removes nothing.
        let insert = TeamsTools.replacementLines(old: "", new: "new line")
        XCTAssertEqual([insert.added, insert.removed], [1, 0])
    }

    func testAddSumsEveryCounter() {
        let a = ToolTally(bash: 1, edit: 2, errors: 1, measured: 3, linesAdded: 10)
        let b = ToolTally(bash: 4, read: 1, errors: 2, measured: 5, linesRemoved: 7)
        let sum = a.adding(b)
        XCTAssertEqual(sum.bash, 5)
        XCTAssertEqual(sum.edit, 2)
        XCTAssertEqual(sum.read, 1)
        XCTAssertEqual(sum.errors, 3)
        XCTAssertEqual(sum.measured, 8)
        XCTAssertEqual(sum.linesAdded, 10)
        XCTAssertEqual(sum.linesRemoved, 7)
    }

    func testCRLFLinesCountLikeRust() {
        XCTAssertEqual(TeamsTools.lineCount("a\r\nb\r\n"), 2)
        let lines = TeamsTools.unifiedDiffLines("-old\r\n+new\r\n")
        XCTAssertEqual([lines.added, lines.removed], [1, 1])
    }
}
