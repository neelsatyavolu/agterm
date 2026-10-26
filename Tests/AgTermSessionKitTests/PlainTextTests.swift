import AgTermCore
import AgTermSessionKit
import SwiftTerm
import XCTest

final class PlainTextTests: XCTestCase {
    private final class NullDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private let delegate = NullDelegate()

    private func lines(_ text: String) -> [String] {
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 40, rows: 4, scrollback: 0))
        terminal.feed(text: text)
        return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.plainText() }
    }

    /// Claude Code steps the cursor over gaps (CSI C) instead of printing spaces; those cells read as spaces.
    func testSkippedCellsAreSpaces() {
        XCTAssertEqual(lines("❯\u{1b}[1C1.\u{1b}[1CYes")[0], "❯ 1. Yes")
    }

    func testWideCharactersHaveNoGap() {
        XCTAssertEqual(lines("中文 ok")[0], "中文 ok")
    }

    /// The question Claude Code's AskUserQuestion draws, as SwiftTerm stores it, reads as a prompt.
    func testAskUserQuestionIsAPrompt() {
        let screen = lines("│ What number should I use? Pick Other.\r\n❯\u{1b}[1C1.\u{1b}[1CI will add it\r\n\u{1b}[2C2.\u{1b}[1CSkip\r\nEnter to select · Esc to cancel")
        XCTAssertTrue(PermissionPrompt.isVisible(screen))
    }
}
