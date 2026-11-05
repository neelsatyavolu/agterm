import AgTermCore
import SwiftTerm

/// A terminal's live screen for agterm Remote: the bottom of the buffer (not wherever a view is
/// scrolled to), with colors and some scrollback above it. The Mac's tabs and a cloud machine's
/// sessions both send it.
public enum ScreenCapture {
    /// `showsCursor`: agents hide the terminal cursor and draw their own, so only plain shells show it.
    public static func snapshot(_ terminal: Terminal, showsCursor: Bool, theme: String) -> ScreenSnapshot {
        let top = terminal.buffer.totalLinesTrimmed
        let end = endRow(terminal, top: top)
        let screenTop = max(top, end - terminal.rows)
        let history = terminal.isCurrentBufferAlternate ? 0 : AgTermWire.screenHistory
        let first = max(top, screenTop - history)
        var lines = (first..<end).map { row in
            terminal.getScrollInvariantLine(row: row).map(runs) ?? []
        }
        let cursor = terminal.getCursorLocation()
        let cursorRow = showsCursor ? screenTop - first + cursor.y : nil
        // Blank rows under the prompt are only padding.
        while lines.count > max((cursorRow ?? -1) + 1, 1), lines.last?.isEmpty == true { lines.removeLast() }
        // Runs skip the right half of wide characters, so count characters, not cells.
        let cursorCol = cursorRow == nil ? nil : terminal.getScrollInvariantLine(row: screenTop + cursor.y).map { line in
            (0..<min(cursor.x, line.count)).filter { line[$0].width != 0 }.count
        } ?? cursor.x
        var snapshot = ScreenSnapshot(cols: terminal.cols, rows: terminal.rows, lines: lines,
                                      cursorRow: cursorRow, cursorCol: cursorCol, theme: theme)
        snapshot.trim(toBytes: AgTermWire.frameBudget)
        return snapshot
    }

    /// The visible screen as plain text, trailing blank rows dropped.
    public static func text(_ terminal: Terminal) -> String {
        var rows = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.plainText() }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows.joined(separator: "\n")
    }

    /// One past the last line in the buffer (SwiftTerm doesn't expose the count).
    public static func endRow(_ terminal: Terminal, top: Int) -> Int {
        guard terminal.getScrollInvariantLine(row: top) != nil else { return top }
        var low = top, step = 1
        while terminal.getScrollInvariantLine(row: low + step) != nil {
            low += step
            step *= 2
        }
        var high = low + step
        while high - low > 1 {
            let mid = (low + high) / 2
            if terminal.getScrollInvariantLine(row: mid) != nil { low = mid } else { high = mid }
        }
        return high
    }

    private static func runs(_ line: BufferLine) -> [ScreenRun] {
        var builder = ScreenLineBuilder()
        for col in 0..<line.count {
            let cell = line[col]
            if cell.width == 0 { continue } // right half of a wide character
            let character = cell.getCharacter()
            builder.add(character == "\u{0}" ? " " : character, fg: ScreenReplay.cellColor(cell.attribute.fg),
                        bg: ScreenReplay.cellColor(cell.attribute.bg), style: CellStyle(rawValue: cell.attribute.style.rawValue))
        }
        return builder.runs
    }
}
