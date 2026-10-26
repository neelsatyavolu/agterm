import Foundation

/// Turns parsed releases into ANSI lines for a terminal. Only indexed SGR colors are used,
/// so the active theme's palette decides how it looks. Lines carry no line ending.
public enum ChangelogRender {
    private static let maxWidth = 78
    private static let historyText = "full history: github.com/neelsatyavolu/agterm/releases"
    private static let esc = "\u{1B}["
    private static let reset = "\u{1B}[0m"

    /// `note` is a dim row inside the header box; nil leaves the box without one.
    public static func lines(_ releases: [Release], columns: Int, note: String? = nil) -> [String] {
        let width = max(1, min(columns, maxWidth))
        var out = header(width: width, note: note)
        for release in releases {
            out.append("")
            out.append(versionLine(release, width: width))
            for item in release.items { out += itemLines(item, width: width) }
        }
        out.append("")
        out += wrap(historyText, width: width - 2).map { "  " + sgr("2", $0) }
        return out
    }

    /// Characters left after removing SGR escapes. Box and marker glyphs are one column wide.
    static func stripSGR(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    static func visibleWidth(_ s: String) -> Int { stripSGR(s).count }

    private static func sgr(_ code: String, _ text: String) -> String { esc + code + "m" + text + reset }

    private static func header(width: Int, note: String?) -> [String] {
        let name = "agterm · what's new"
        let top: String
        if width >= name.count + 6 {
            // ╭─ name ─…╮ with the name in bold and the frame dim.
            let rule = String(repeating: "─", count: width - name.count - 6)
            top = sgr("2", "╭─ ") + sgr("1", name) + sgr("2", " ─" + rule + "╮")
        } else {
            top = sgr("2", "╭" + String(repeating: "─", count: max(0, width - 2)) + "╮")
        }
        let bottom = sgr("2", "╰" + String(repeating: "─", count: max(0, width - 2)) + "╯")
        guard let note, width >= 4 else { return [top, bottom] }
        let inner = width - 4
        let text = String(note.prefix(inner))
        let pad = String(repeating: " ", count: inner - text.count)
        return [top, sgr("2", "│ " + text + pad + " │"), bottom]
    }

    private static func versionLine(_ release: Release, width: Int) -> String {
        let badgeText = " v\(release.version) "
        var used = badgeText.count
        var line = sgr("44;97", badgeText)
        if let date = release.date, !date.isEmpty {
            line += " " + sgr("2", date)
            used += 1 + date.count
        }
        let rule = width - used - 1
        if rule > 0 { line += " " + sgr("2", String(repeating: "─", count: rule)) }
        return line
    }

    private static func itemLines(_ item: Item, width: Int) -> [String] {
        let (glyph, code): (String, String) = {
            switch item.kind {
            case .added: return ("+", "32")
            case .changed: return ("~", "33")
            case .fixed: return ("✓", "34")
            case .other: return ("·", "2")
            }
        }()
        let wrapped = wrap(item.text, width: width - 4)
        guard let first = wrapped.first else { return ["  " + sgr(code, glyph)] }
        return ["  " + sgr(code, glyph) + " " + first] + wrapped.dropFirst().map { "    " + $0 }
    }

    /// Greedy word wrap; a word longer than `width` is split by characters.
    private static func wrap(_ text: String, width: Int) -> [String] {
        let width = max(1, width)
        var lines: [String] = []
        var current = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            var rest = Substring(word)
            while rest.count > width {
                if !current.isEmpty { lines.append(current); current = "" }
                lines.append(String(rest.prefix(width)))
                rest = rest.dropFirst(width)
            }
            if current.isEmpty {
                current = String(rest)
            } else if current.count + 1 + rest.count <= width {
                current += " " + rest
            } else {
                lines.append(current)
                current = String(rest)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
