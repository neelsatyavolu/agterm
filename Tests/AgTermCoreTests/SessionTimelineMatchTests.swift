import XCTest
@testable import AgTermCore

/// Finding a Session Timeline turn in the terminal's rows, and shell commands from prompt marks.
final class SessionTimelineMatchTests: XCTestCase {
    func testFindsClaudePromptAndRepeats() {
        let lines = [
            "> run the tests",
            "  Ran 12 tests",
            "",
            "> fix the flaky one in",
            "  LoginTests",
            "⏺ I'll fix the flaky one in LoginTests.",
            "> run the tests",
            "",
        ]
        XCTAssertEqual(SessionTimelineMatch.promptRow(in: lines, prompt: "run the tests"), 6)
        XCTAssertEqual(SessionTimelineMatch.promptRow(in: lines, prompt: "run the tests", occurrenceFromEnd: 1), 0)
        XCTAssertEqual(SessionTimelineMatch.promptRow(in: lines, prompt: "fix the flaky one in\nLoginTests"), 3)
        XCTAssertNil(SessionTimelineMatch.promptRow(in: lines, prompt: "never sent"))
        XCTAssertNil(SessionTimelineMatch.promptRow(in: lines, prompt: "run the tests", occurrenceFromEnd: 2))
    }

    func testPrefersMarkedRowsOverQuotes() {
        let lines = ["❯ deploy now", "deploy now", "ok"]
        XCTAssertEqual(SessionTimelineMatch.promptRow(in: lines, prompt: "deploy now"), 0)
    }

    func testShortenedPastedPrompt() {
        let lines = ["> Here is the stack trace from production [Pasted text #1 +40 lines]", "  ⎿ reading"]
        let prompt = "Here is the stack trace from production\n" + String(repeating: "at frame\n", count: 40)
        XCTAssertEqual(SessionTimelineMatch.promptRow(in: lines, prompt: prompt), 0)
    }

    func testCodexNeedsMarker() {
        let lines = [
            "› Rename the module",
            "• Rename the module done.",
            "› Rename the module",
            "  and its tests",
        ]
        XCTAssertEqual(SessionTimelineMatch.promptRow(in: lines, prompt: "Rename the module and its tests", codex: true), 2)
        // Without the marker, the answer quoting the prompt doesn't count.
        XCTAssertNil(SessionTimelineMatch.promptRow(in: ["• Rename the module done."], prompt: "Rename the module done.", codex: true))
    }

    func testPromptHeight() {
        let lines = ["> one", "  two", "output", "", "> next"]
        XCTAssertEqual(SessionTimelineMatch.promptRows(in: lines, prompt: "one two"), 0..<2)
        XCTAssertEqual(SessionTimelineMatch.promptRows(in: lines, prompt: "next"), 4..<5)
    }

    func testGrokFocus() {
        XCTAssertEqual(SessionTimelineMatch.grokFocus(["", " shift+tab:mode  enter:send  opt+enter:newline"]), .prompt)
        XCTAssertEqual(SessionTimelineMatch.grokFocus(["j/k:nav  shift+l/h:turn  g/shift+g:top/btm"]), .scrollback)
        XCTAssertEqual(SessionTimelineMatch.grokFocus(["hello"]), .unknown)
        XCTAssertEqual(SessionTimelineMatch.fingerprint(["Working 12s"]), SessionTimelineMatch.fingerprint(["Working 13s"]))
    }

    // MARK: Shell

    func testShellCommands() {
        typealias Row = SessionTimelineShell.Row
        let rows = [
            Row(hasPrompt: true, input: "ls -la"),
            Row(hasOutput: true),
            Row(hasPrompt: true, input: ""),
            Row(hasPrompt: true, input: "echo a very long com"),
            Row(input: "mand", isWrapped: true),
            Row(hasOutput: true),
            Row(hasPrompt: true, input: "git sta"),
        ]
        let idle = SessionTimelineShell.commands(rows, running: false)
        XCTAssertEqual(idle.map(\.prompt), ["ls -la", "echo a very long command"])
        XCTAssertEqual(idle.map(\.row), [0, 3])
        XCTAssertEqual(idle.map(\.status), [.done, .done])

        let busy = SessionTimelineShell.commands(Array(rows.dropLast()) + [Row(hasPrompt: true, input: "sleep 5")], running: true)
        XCTAssertEqual(busy.map(\.prompt), ["ls -la", "echo a very long command", "sleep 5"])
        XCTAssertEqual(busy.last?.status, .running)
    }
}
