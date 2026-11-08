import Foundation

/// A run of an agent's reply with one style.
public struct ChatSpan: Equatable, Sendable {
    public enum Style: Equatable, Sendable { case plain, bold, code }
    public let style: Style
    public let text: String

    public init(_ style: Style, _ text: String) {
        self.style = style
        self.text = text
    }
}

/// One line of an agent's reply as the chat draws it: markdown reduced to what a monospaced
/// transcript can show (bold headings, bullets, code wells, tables as aligned columns).
public enum ChatTextLine: Equatable, Sendable {
    case text([ChatSpan])
    case heading([ChatSpan])
    /// `marker` is "•" for -, * and +, or the item's own number ("2.").
    case bullet(indent: Int, marker: String, [ChatSpan])
    case quote([ChatSpan])
    /// A fenced code block's lines, verbatim.
    case code([String])
    /// A table row, cells padded to their column's width; the header comes first.
    case tableRow(String, header: Bool)
    case blank
}

/// Markdown → `ChatTextLine`s. Fences open with ``` or ~~~ (3 or more) and close only on the same
/// character at least as long, so a ``` inside a ~~~~ block stays code.
public enum ChatText {
    public static func lines(_ markdown: String) -> [ChatTextLine] {
        var out: [ChatTextLine] = []
        var prose: [String] = []
        var fence: (char: Character, count: Int, lines: [String])?

        for line in markdown.components(separatedBy: "\n") {
            if var open = fence {
                if let close = fenceMark(line), close.char == open.char, close.count >= open.count, close.rest.isEmpty {
                    out.append(.code(open.lines))
                    fence = nil
                } else {
                    open.lines.append(line)
                    fence = open
                }
                continue
            }
            if let mark = fenceMark(line) {
                out += proseLines(prose)
                prose = []
                fence = (mark.char, mark.count, [])
                continue
            }
            prose.append(line)
        }
        out += proseLines(prose)
        // An unclosed fence (a reply still streaming) shows what it has as code.
        if let open = fence { out.append(.code(open.lines)) }
        return trimBlanks(out)
    }

    /// `**bold**` and `` `code` `` within a line; everything else stays as typed.
    public static func spans(_ line: String) -> [ChatSpan] {
        var out: [ChatSpan] = []
        var plain = ""
        var rest = Substring(line)
        func flush() {
            if !plain.isEmpty { out.append(ChatSpan(.plain, plain)) }
            plain = ""
        }
        while let char = rest.first {
            if char == "`", let end = rest.dropFirst().firstIndex(of: "`") {
                flush()
                out.append(ChatSpan(.code, String(rest[rest.index(after: rest.startIndex)..<end])))
                rest = rest[rest.index(after: end)...]
            } else if rest.hasPrefix("**"), let end = rest.dropFirst(2).range(of: "**"), end.lowerBound > rest.index(rest.startIndex, offsetBy: 2) {
                flush()
                out.append(ChatSpan(.bold, String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound])))
                rest = rest[end.upperBound...]
            } else {
                plain.append(char)
                rest = rest.dropFirst()
            }
        }
        flush()
        return out
    }

    // MARK: Prose

    private static func proseLines(_ lines: [String]) -> [ChatTextLine] {
        guard !lines.isEmpty else { return [] }
        var out: [ChatTextLine] = []
        // Tables come from the phone's parser; fences are already gone, so its fence toggle never fires.
        for block in ChatMarkdown.blocks(lines.joined(separator: "\n")) {
            switch block {
            case .table(let table):
                if !out.isEmpty { out.append(.blank) }
                out += tableRows(table)
                out.append(.blank)
            case .text(let text):
                out += text.components(separatedBy: "\n").map(proseLine)
            }
        }
        return out
    }

    private static func proseLine(_ line: String) -> ChatTextLine {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .blank }
        if let hashes = trimmed.firstIndex(where: { $0 != "#" }), (1...6).contains(trimmed.distance(from: trimmed.startIndex, to: hashes)),
           trimmed[hashes] == " " {
            return .heading(spans(trimmed[hashes...].trimmingCharacters(in: .whitespaces)))
        }
        if trimmed.hasPrefix("> ") || trimmed == ">" { return .quote(spans(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))) }
        let indent = line.prefix { $0 == " " }.count / 2
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
            return .bullet(indent: indent, marker: "•", spans(String(trimmed.dropFirst(2))))
        }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        if (1...3).contains(digits.count), let mark = trimmed.dropFirst(digits.count).first, mark == "." || mark == ")",
           trimmed.dropFirst(digits.count + 1).first == " " {
            return .bullet(indent: indent, marker: String(digits) + ".", spans(String(trimmed.dropFirst(digits.count + 2))))
        }
        return .text(spans(line))
    }

    private static func tableRows(_ table: ChatMarkdown.Table) -> [ChatTextLine] {
        let all = [table.header] + table.rows
        let widths = table.header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        func row(_ cells: [String]) -> String {
            zip(cells, widths).map { $0 + String(repeating: " ", count: $1 - $0.count) }.joined(separator: "  ").rustTrimEnd
        }
        return [.tableRow(row(table.header), header: true)] + table.rows.map { .tableRow(row($0), header: false) }
    }

    // MARK: Fences

    /// ```` ```swift ```` → (`, 3, "swift"). Up to three spaces of indent, like CommonMark.
    private static func fenceMark(_ line: String) -> (char: Character, count: Int, rest: String)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let body = line.dropFirst(indent)
        guard let char = body.first, char == "`" || char == "~" else { return nil }
        let count = body.prefix { $0 == char }.count
        guard count >= 3 else { return nil }
        let rest = body.dropFirst(count).trimmingCharacters(in: .whitespaces)
        // A backtick fence's info string can't hold a backtick (that's inline code).
        if char == "`", rest.contains("`") { return nil }
        return (char, count, rest)
    }

    private static func trimBlanks(_ lines: [ChatTextLine]) -> [ChatTextLine] {
        var out: [ChatTextLine] = []
        for line in lines where !(line == .blank && (out.isEmpty || out.last == .blank)) { out.append(line) }
        while out.last == .blank { out.removeLast() }
        return out
    }
}
