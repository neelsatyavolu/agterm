import AgTermCore
import SwiftTerm

/// Reads a terminal's history back out as text with ANSI colors, so a restored tab looks like it
/// did at quit. Wrapped rows are joined, so the text reflows if the window size changed.
enum Scrollback {
    static let maxLines = 10_000

    static func capture(_ terminal: Terminal) -> String {
        // Full-screen programs (vim, less) use the alternate screen; save the shell history beneath.
        if terminal.isCurrentBufferAlternate {
            return String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: "\r\n")
        }
        var rows: [BufferLine] = []
        var row = terminal.buffer.totalLinesTrimmed
        while let line = terminal.getScrollInvariantLine(row: row) {
            rows.append(line)
            row += 1
        }
        while let last = rows.last, isBlank(last) { rows.removeLast() }
        rows = Array(rows.suffix(maxLines))

        var out = ""
        var current = Attribute.empty
        for (i, line) in rows.enumerated() {
            if i > 0, !line.isWrapped { out += "\r\n" }
            let end = lastVisibleColumn(line)
            var col = 0
            while col <= end {
                let cell = line[col]
                col += 1
                if cell.width == 0 { continue } // right half of a wide character
                if cell.attribute != current {
                    out += sgr(cell.attribute)
                    current = cell.attribute
                }
                out.append(cell.getCharacter())
            }
            // Reset at line ends so a background color never bleeds into the padding.
            if current != .empty {
                out += "\u{1b}[0m"
                current = .empty
            }
        }
        return out
    }

    private static func isBlank(_ line: BufferLine) -> Bool {
        lastVisibleColumn(line) < 0
    }

    /// Index of the last cell with a character or a non-default background, or -1.
    private static func lastVisibleColumn(_ line: BufferLine) -> Int {
        var col = line.count - 1
        while col >= 0 {
            let cell = line[col]
            let ch = cell.getCharacter()
            if (ch != " " && ch != "\u{0}") || !isDefault(cell.attribute.bg) { return col }
            col -= 1
        }
        return -1
    }

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

    static func cellColor(_ color: Attribute.Color) -> CellColor {
        switch color {
        case .ansi256(let code): .ansi(code)
        case let .trueColor(r, g, b): .rgb(r, g, b)
        default: .default
        }
    }
}
