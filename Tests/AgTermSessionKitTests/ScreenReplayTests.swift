import AgTermSessionKit
import SwiftTerm
import XCTest

final class ScreenReplayTests: XCTestCase {
    private let delegate = NullDelegate()

    private func makeTerminal(cols: Int = 20, rows: Int = 5) -> Terminal {
        Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows, scrollback: 1_000))
    }

    private func source(_ text: String, cols: Int = 20, rows: Int = 5) -> Terminal {
        let terminal = makeTerminal(cols: cols, rows: rows)
        terminal.feed(text: text)
        return terminal
    }

    /// A fresh terminal of `source`'s size (or `cols`) fed `ScreenReplay.bytes(source)`.
    private func replay(_ source: Terminal, cols: Int? = nil) -> Terminal {
        let terminal = makeTerminal(cols: cols ?? source.cols, rows: source.rows)
        terminal.feed(byteArray: [UInt8](ScreenReplay.bytes(source)))
        return terminal
    }

    private func screen(_ terminal: Terminal) -> [String] {
        (0..<terminal.rows).map { terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "<nil>" }
    }

    private func normalText(_ terminal: Terminal) -> String {
        String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
    }

    private func assertSameScreen(_ a: Terminal, _ b: Terminal, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(screen(a), screen(b), "screen rows", file: file, line: line)
        XCTAssertEqual(a.getCursorLocation().x, b.getCursorLocation().x, "cursor x", file: file, line: line)
        XCTAssertEqual(a.getCursorLocation().y, b.getCursorLocation().y, "cursor y", file: file, line: line)
    }

    func testPlainScreenAndCursorMatch() {
        let lines = (1...9).map { "line \($0)" }.joined(separator: "\r\n")
        let original = source(lines + "\r\n$ ls -la")
        let copy = replay(original)
        assertSameScreen(original, copy)
        XCTAssertEqual(normalText(original), normalText(copy))
        XCTAssertEqual(copy.getCursorLocation().x, 8)
    }

    func testCursorInsideTextAndBlankRowsBelow() {
        let original = source("one\r\ntwo\r\nthree\u{1b}[1;2H")
        assertSameScreen(original, replay(original))
    }

    func testColorsSurvive() {
        let original = source("\u{1b}[31mred\u{1b}[0m plain \u{1b}[38;2;1;2;3;48;5;200mrgb\u{1b}[0m")
        let copy = replay(original)
        XCTAssertEqual(copy.getCharData(col: 0, row: 0)?.attribute.fg, original.getCharData(col: 0, row: 0)?.attribute.fg)
        XCTAssertEqual(copy.getCharData(col: 0, row: 0)?.attribute.fg, .ansi256(code: 1))
        XCTAssertEqual(copy.getCharData(col: 10, row: 0)?.attribute, original.getCharData(col: 10, row: 0)?.attribute)
        XCTAssertEqual(copy.getCharData(col: 4, row: 0)?.attribute, original.getCharData(col: 4, row: 0)?.attribute)
        assertSameScreen(original, copy)
    }

    func testAltScreenRestored() {
        let history = (1...8).map { "shell \($0)" }.joined(separator: "\r\n")
        let original = source(history + "\r\n$ vim\u{1b}[?1049h\u{1b}[H\u{1b}[2J\u{1b}[1;1Hfile.txt\u{1b}[3;4H\u{1b}[7mstatus\u{1b}[0m\u{1b}[2;2H")
        let copy = replay(original)
        XCTAssertTrue(copy.isCurrentBufferAlternate)
        assertSameScreen(original, copy)
        XCTAssertEqual(normalText(original), normalText(copy), "normal-buffer history still above")
        XCTAssertEqual(copy.getCharData(col: 3, row: 2)?.attribute, original.getCharData(col: 3, row: 2)?.attribute)

        // Leaving the alt screen lands where the shell's cursor was.
        original.feed(text: "\u{1b}[?1049l")
        copy.feed(text: "\u{1b}[?1049l")
        XCTAssertFalse(copy.isCurrentBufferAlternate)
        assertSameScreen(original, copy)
    }

    func testModesRestored() {
        let original = source("$ \u{1b}[?1h\u{1b}[?2004h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?25l")
        let copy = replay(original)
        XCTAssertTrue(copy.applicationCursor)
        XCTAssertTrue(copy.bracketedPasteMode)
        XCTAssertEqual(copy.mouseMode, original.mouseMode)
        XCTAssertEqual(copy.mouseMode, .buttonEventTracking)
        XCTAssertEqual(copy.mouseEncodingMode, 1006)
        XCTAssertTrue(copy.isCursorHidden)
        assertSameScreen(original, copy)
    }

    func testDefaultModesStayDefault() {
        let copy = replay(source("$ "))
        XCTAssertFalse(copy.applicationCursor)
        XCTAssertFalse(copy.bracketedPasteMode)
        XCTAssertEqual(copy.mouseMode, .off)
        XCTAssertNil(copy.mouseEncodingMode)
        XCTAssertFalse(copy.isCursorHidden)
        XCTAssertTrue(copy.isWraparound)
        XCTAssertEqual(copy.options.cursorStyle, TerminalOptions.default.cursorStyle)
    }

    func testMoreModesRestored() {
        let original = source("\u{1b}[?66h\u{1b}[?1004h\u{1b}[?7l\u{1b}[4h\u{1b}[?1007l\u{1b}[6 q\u{1b}[?1003h\u{1b}[>1u$ ")
        let copy = replay(original)
        XCTAssertTrue(copy.isApplicationKeypad)
        XCTAssertTrue(copy.isFocusReporting)
        XCTAssertFalse(copy.isWraparound)
        XCTAssertTrue(copy.isInsertMode)
        XCTAssertFalse(copy.alternateScrollMode)
        XCTAssertEqual(copy.options.cursorStyle, .steadyBar)
        XCTAssertEqual(copy.mouseMode, .anyEvent)
        XCTAssertEqual(copy.keyboardEnhancementFlags, original.keyboardEnhancementFlags)
        XCTAssertEqual(copy.keyboardEnhancementFlags.rawValue, 1)
        assertSameScreen(original, copy)
    }

    func testTitleRestored() {
        let original = source("\u{1b}]0;✳ Claude Code\u{7}$ ")
        XCTAssertEqual(original.windowTitle, "✳ Claude Code")
        XCTAssertEqual(replay(original).windowTitle, "✳ Claude Code")
    }

    func testCurrentAttributeRestored() {
        let original = source("$ \u{1b}[1;32;44m")
        let copy = replay(original)
        XCTAssertEqual(copy.currentAttribute, original.currentAttribute)
        original.feed(text: "x")
        copy.feed(text: "x")
        XCTAssertEqual(copy.getCharData(col: 2, row: 0)?.attribute, original.getCharData(col: 2, row: 0)?.attribute)
    }

    func testScrollRegionRestored() {
        let original = source("a\r\nb\r\nc\r\nd\u{1b}[2;4r\u{1b}[3;5H")
        let copy = replay(original)
        XCTAssertEqual(copy.buffer.scrollTop, 1)
        XCTAssertEqual(copy.buffer.scrollBottom, 3)
        assertSameScreen(original, copy)
        // Scrolling inside the region behaves the same.
        original.feed(text: "\u{1b}[4;1H\r\nnew")
        copy.feed(text: "\u{1b}[4;1H\r\nnew")
        assertSameScreen(original, copy)
    }

    func testOriginModeCursor() {
        let original = source("a\r\nb\u{1b}[2;4r\u{1b}[?6h\u{1b}[2;3H")
        let copy = replay(original)
        assertSameScreen(original, copy)
        XCTAssertTrue(copy.isOriginMode)
    }

    func testSavedCursorRestored() {
        let original = source("hello\u{1b}[2;3H\u{1b}7\u{1b}[5;1Hbottom")
        let copy = replay(original)
        original.feed(text: "\u{1b}8")
        copy.feed(text: "\u{1b}8")
        assertSameScreen(original, copy)
    }

    func testWideCharRowMatches() {
        let original = source("a中b🙂c\r\n日本語テキスト")
        let copy = replay(original)
        assertSameScreen(original, copy)
        XCTAssertEqual(copy.getCharacter(col: 4, row: 0), "🙂")
        for col in 0..<8 {
            XCTAssertEqual(copy.getCharData(col: col, row: 0)?.width, original.getCharData(col: col, row: 0)?.width, "col \(col)")
        }
    }

    func testGapsKeepTheirColumns() {
        let original = source("ab\u{1b}[5Ccd\u{1b}[2;10Hx")
        assertSameScreen(original, replay(original))
    }

    func testWrappedLineWithTrailingSpaces() {
        let original = source("abc" + String(repeating: " ", count: 17) + "next row\r\n$ ")
        let copy = replay(original)
        assertSameScreen(original, copy)
        XCTAssertEqual(copy.getLine(row: 1)?.isWrapped, true)
    }

    func testCursorAfterLastColumnWrapsLikeTheSource() {
        for line in ["$ " + String(repeating: "x", count: 18), "$ " + String(repeating: "中", count: 9)] {
            let original = source("\u{1b}[33m" + line)
            let copy = replay(original)
            assertSameScreen(original, copy)
            original.feed(text: "y")
            copy.feed(text: "y")
            assertSameScreen(original, copy)
            XCTAssertEqual(copy.getCharData(col: 0, row: 1)?.attribute, original.getCharData(col: 0, row: 1)?.attribute)
        }
    }

    func testDifferentColumnCountDoesNotCrash() {
        let long = String(repeating: "wide wide wide ", count: 6)
        let original = source("\u{1b}[32m" + long + "\u{1b}[0m\r\n中文 text\u{1b}[?1049h\u{1b}[3;30Hfar right\u{1b}[2;5r", cols: 40, rows: 6)
        let narrow = replay(original, cols: 10)
        XCTAssertTrue(narrow.isCurrentBufferAlternate)
        let wide = replay(original, cols: 120)
        XCTAssertTrue(wide.isCurrentBufferAlternate)
        XCTAssertTrue(normalText(wide).contains("wide wide"))
    }

    func testHistoryKeepsColorsAndDropsTrailingBlankRows() {
        let terminal = source("\u{1b}[31mred\u{1b}[0m\r\nplain\r\n")
        XCTAssertEqual(ScreenReplay.history(terminal), "\u{1b}[0;31mred\u{1b}[0m\r\nplain")
    }

    func testHistoryKeepsEmojiAtRowEnd() {
        let terminal = source("done 🙂\r\nnext")
        XCTAssertEqual(ScreenReplay.history(terminal), "done 🙂\r\nnext")
    }

    func testHistoryKeepsRowOfOnlyEmoji() {
        let terminal = source("first\r\n🙂🎉")
        XCTAssertEqual(ScreenReplay.history(terminal), "first\r\n🙂🎉")
    }

    func testSavedCursorColorDoesNotLeakIntoAltScreen() {
        let original = source("shell\u{1b}[31m\u{1b}[?1049h\u{1b}[0m\u{1b}[2;1Hplain\u{1b}[3;1H\u{1b}[32m\u{1b}7\u{1b}[0mmore")
        let copy = replay(original)
        assertSameScreen(original, copy)
        for (col, row) in [(0, 1), (4, 1), (0, 2), (3, 2)] {
            XCTAssertEqual(copy.getCharData(col: col, row: row)?.attribute,
                           original.getCharData(col: col, row: row)?.attribute, "col \(col) row \(row)")
        }
    }

    func testPendingWrapReprintOfDefaultCellDoesNotTakeSavedColor() {
        let original = source("\u{1b}[31m\u{1b}7\u{1b}[0m$ " + String(repeating: "x", count: 18))
        let copy = replay(original)
        XCTAssertEqual(copy.getCharData(col: 19, row: 0)?.attribute, original.getCharData(col: 19, row: 0)?.attribute)
        assertSameScreen(original, copy)
    }

    func testHistoryOfAltScreenIsTheShellBeneath() {
        let terminal = source("shell\u{1b}[?1049hfull screen app")
        XCTAssertEqual(ScreenReplay.history(terminal), "shell")
    }

    func testHistoryIsCapped() {
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 5, scrollback: 20_000))
        terminal.feed(text: (1...(ScreenReplay.maxLines + 500)).map(String.init).joined(separator: "\r\n"))
        let history = ScreenReplay.history(terminal)
        XCTAssertEqual(history.components(separatedBy: "\r\n").count, ScreenReplay.maxLines)
        XCTAssertTrue(history.hasSuffix("\(ScreenReplay.maxLines + 500)"))
        let bytes = String(decoding: ScreenReplay.bytes(terminal), as: UTF8.self)
        XCTAssertLessThanOrEqual(bytes.components(separatedBy: "\r\n").count, ScreenReplay.maxLines)
    }
}

private final class NullDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
