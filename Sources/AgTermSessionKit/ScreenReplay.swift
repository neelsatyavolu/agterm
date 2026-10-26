import AgTermCore
import Foundation
import SwiftTerm

/// What a client is sent on attach so a fresh terminal shows and behaves like the session's: its
/// history, screen, colors, alternate screen, modes, cursor and title. Also reads a terminal's
/// history back out as text for the app's quit/restore path.
public enum ScreenReplay {
    /// The most buffer rows `history` and `bytes` emit.
    public static let maxLines = 10_000

    private static let esc = "\u{1b}"

    /// The normal buffer's rows as text with ANSI colors, trailing blank rows dropped. Wrapped rows
    /// are joined, so the text reflows if it is fed to a terminal of another width. While a
    /// full-screen program (vim, less) has the alternate screen, this is the shell history beneath.
    public static func history(_ terminal: Terminal) -> String {
        var lines = rows(terminal.buffer(kind: .normal))
        while let last = lines.last, lastVisibleColumn(last) < 0 { lines.removeLast() }
        return text(Array(lines.suffix(maxLines)), terminal, keepSpaces: false)
    }

    /// Bytes that rebuild `terminal` in a fresh terminal: reset, the normal buffer's history and
    /// screen, the alternate screen if active, then modes, cursor, current colors and title.
    public static func bytes(_ terminal: Terminal) -> Data {
        // Blank screen rows are kept so the screen's rows line up with the source's.
        let normal = terminal.buffer(kind: .normal)
        var out = esc + "c" + text(Array(rows(normal).suffix(maxLines)), terminal, keepSpaces: true)
        out += regionAndSavedCursor(normal, terminal)
        if terminal.isCurrentBufferAlternate {
            // 1049 saves the cursor (placed at the normal buffer's saved one), so leaving the
            // alternate screen later lands where the shell's cursor was.
            out += esc + "[?1049h" + altScreen(terminal.buffer(kind: .alt), terminal)
            out += regionAndSavedCursor(terminal.buffer(kind: .alt), terminal)
        }
        out += modes(terminal) + cursor(terminal) + sgr(terminal.currentAttribute) + titles(terminal)
        return Data(out.utf8)
    }

    // MARK: Rows

    /// Scrollback and screen rows, oldest first.
    private static func rows(_ buffer: Buffer) -> [BufferLine] {
        (0..<buffer.lineCount).map(buffer.line(at:))
    }

    /// Rows joined by CR LF, except where a row continues the one above it (it wrapped).
    private static func text(_ lines: [BufferLine], _ terminal: Terminal, keepSpaces: Bool) -> String {
        var out = ""
        for (i, line) in lines.enumerated() {
            if i > 0, !line.isWrapped { out += "\r\n" }
            // A row that wraps into the next keeps its trailing blanks so the wrap point holds.
            let wraps = i + 1 < lines.count && lines[i + 1].isWrapped
            let end = wraps ? line.count - 1 : lastVisibleColumn(line, keepSpaces: keepSpaces)
            out += cells(line, through: end, terminal)
        }
        return out
    }

    /// The alternate screen's non-blank rows, each placed with a cursor move.
    private static func altScreen(_ buffer: Buffer, _ terminal: Terminal) -> String {
        var out = ""
        for row in 0..<terminal.rows where buffer.screenTop + row < buffer.lineCount {
            let line = buffer.line(at: buffer.screenTop + row)
            let end = lastVisibleColumn(line, keepSpaces: true)
            if end >= 0 { out += "\(esc)[\(row + 1);1H" + cells(line, through: end, terminal) }
        }
        return out
    }

    /// One row's cells up to `end` with SGR changes, ending with default colors so a background
    /// never bleeds into the padding. Unwritten cells are skipped with a cursor move.
    private static func cells(_ line: BufferLine, from start: Int = 0, through end: Int,
                              _ terminal: Terminal) -> String {
        let base = CharData.Null.attribute
        var out = ""
        var current = base
        var gap = 0
        for col in start..<max(start, min(end + 1, line.count)) {
            let cell = line[col]
            if cell.width == 0 { continue } // right half of a wide character
            let unwritten = cell.getCharacter() == "\u{0}"
            if unwritten, isDefault(cell.attribute.bg) {
                gap += 1
                continue
            }
            if gap > 0 { out += "\(esc)[\(gap)C" }
            gap = 0
            if cell.attribute != current {
                out += sgr(cell.attribute)
                current = cell.attribute
            }
            out.append(unwritten ? " " : terminal.getCharacter(for: cell))
        }
        if gap > 0 { out += "\(esc)[\(gap)C" }
        if current != base { out += "\(esc)[0m" }
        return out
    }

    /// Index of the last cell with a character (a space counts only with `keepSpaces`) or a
    /// non-default background, or -1.
    private static func lastVisibleColumn(_ line: BufferLine, keepSpaces: Bool = false) -> Int {
        var col = line.count - 1
        while col >= 0 {
            let cell = line[col]
            let ch = cell.getCharacter()
            if ((keepSpaces || ch != " ") && ch != "\u{0}") || !isDefault(cell.attribute.bg) { return col }
            col -= 1
        }
        return -1
    }

    // MARK: State

    /// The buffer's scroll region (DECSTBM homes the cursor, so it goes first), then its saved
    /// cursor and colors, stored with DECSC.
    private static func regionAndSavedCursor(_ buffer: Buffer, _ terminal: Terminal) -> String {
        var out = ""
        if buffer.scrollTop != 0 || buffer.scrollBottom != terminal.rows - 1 {
            out += "\(esc)[\(buffer.scrollTop + 1);\(buffer.scrollBottom + 1)r"
        }
        return out + "\(esc)[\(buffer.savedY + 1);\(buffer.savedX + 1)H" + sgr(buffer.savedAttr) + esc + "7"
    }

    /// Modes that differ from a reset terminal's.
    private static func modes(_ terminal: Terminal) -> String {
        var set: [String] = []
        if terminal.applicationCursor { set.append("?1") }
        if terminal.isApplicationKeypad { set.append("?66") }
        if terminal.bracketedPasteMode { set.append("?2004") }
        if terminal.isFocusReporting { set.append("?1004") }
        if let mouse = mouseMode(terminal.mouseMode) { set.append("?\(mouse)") }
        if let encoding = terminal.mouseEncodingMode { set.append("?\(encoding)") }
        if terminal.isInsertMode { set.append("4") }
        // DECOM homes the cursor; `cursor` places it afterwards, relative to the region.
        if terminal.isOriginMode { set.append("?6") }
        var out = set.map { "\(esc)[\($0)h" }.joined()
        if !terminal.isWraparound { out += "\(esc)[?7l" }
        if !terminal.alternateScrollMode { out += "\(esc)[?1007l" }
        // 1049 shows the cursor, so this comes after the alternate screen. RIS keeps a hidden
        // cursor hidden, so a visible one is stated too.
        out += "\(esc)[?25" + (terminal.isCursorHidden ? "l" : "h")
        if terminal.options.cursorStyle != TerminalOptions.default.cursorStyle {
            out += "\(esc)[\(decscusr(terminal.options.cursorStyle)) q"
        }
        let flags = terminal.keyboardEnhancementFlags.rawValue
        if flags != 0 { out += "\(esc)[>\(flags)u" }
        return out
    }

    /// The cursor, relative to the scroll region under DECOM. A cursor past the last column (a wrap
    /// is pending) is rebuilt by printing the row's last character again.
    private static func cursor(_ terminal: Terminal) -> String {
        let buffer = terminal.buffer
        let row = buffer.y - (terminal.isOriginMode ? buffer.scrollTop : 0) + 1
        let index = buffer.screenTop + buffer.y
        guard buffer.x >= terminal.cols, terminal.cols >= 2, index < buffer.lineCount else {
            return "\(esc)[\(row);\(buffer.x + 1)H"
        }
        let line = buffer.line(at: index)
        let col = line[terminal.cols - 1].width == 0 ? terminal.cols - 2 : terminal.cols - 1
        let reprint = "\(esc)[\(row);\(col + 1)H" + cells(line, from: col, through: terminal.cols - 1, terminal)
        // Insert mode would shift the row while printing.
        return terminal.isInsertMode ? "\(esc)[4l" + reprint + "\(esc)[4h" : reprint
    }

    private static func titles(_ terminal: Terminal) -> String {
        var out = ""
        let title = terminal.windowTitle.filter { !$0.isASCIIControl }
        if !title.isEmpty { out += "\(esc)]0;\(title)\u{7}" }
        if let directory = terminal.hostCurrentDirectory, !directory.contains(where: \.isASCIIControl) {
            out += "\(esc)]7;\(directory)\u{7}"
        }
        return out
    }

    private static func mouseMode(_ mode: Terminal.MouseMode) -> Int? {
        switch mode {
        case .off: nil
        case .x10: 9
        case .vt200: 1000
        case .buttonEventTracking: 1002
        case .anyEvent: 1003
        }
    }

    private static func decscusr(_ style: CursorStyle) -> Int {
        switch style {
        case .blinkBlock: 1
        case .steadyBlock: 2
        case .blinkUnderline: 3
        case .steadyUnderline: 4
        case .blinkBar: 5
        case .steadyBar: 6
        }
    }

    // MARK: Colors

    private static func isDefault(_ color: Attribute.Color) -> Bool {
        switch color {
        case .defaultColor, .defaultInvertedColor: true
        default: false
        }
    }

    private static func sgr(_ attribute: Attribute) -> String {
        SGR.sequence(fg: cellColor(attribute.fg), bg: cellColor(attribute.bg),
                     style: CellStyle(rawValue: attribute.style.rawValue))
    }

    public static func cellColor(_ color: Attribute.Color) -> CellColor {
        switch color {
        case .ansi256(let code): .ansi(code)
        case let .trueColor(r, g, b): .rgb(r, g, b)
        default: .default
        }
    }
}

private extension Character {
    var isASCIIControl: Bool { asciiValue.map { $0 < 0x20 || $0 == 0x7f } ?? false }
}
