import Foundation

/// Splits an agent's reply into text and GitHub-style tables, so the phone's Chat view can draw
/// tables as grids. Text blocks keep their markdown for inline rendering.
public enum ChatMarkdown {
    public enum Alignment: Equatable, Sendable { case leading, center, trailing }

    public struct Table: Equatable, Sendable {
        public let header: [String]
        public let alignments: [Alignment]
        /// Every row has exactly `header.count` cells.
        public let rows: [[String]]

        public init(header: [String], alignments: [Alignment], rows: [[String]]) {
            self.header = header
            self.alignments = alignments
            self.rows = rows
        }
    }

    public enum Block: Equatable, Sendable {
        case text(String)
        case table(Table)
    }

    public static func blocks(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var pending: [String] = []
        var inFence = false
        var i = 0

        func flushText() {
            let joined = pending.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(.text(joined)) }
            pending = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, i + 1 < lines.count, let table = tableStart(header: line, delimiter: lines[i + 1]) {
                var rows: [[String]] = []
                var next = i + 2
                while next < lines.count, isBodyRow(lines[next]) {
                    rows.append(fitted(cells(lines[next]), to: table.header.count))
                    next += 1
                }
                flushText()
                blocks.append(.table(Table(header: table.header, alignments: table.alignments, rows: rows)))
                i = next
                continue
            }
            pending.append(line)
            i += 1
        }
        flushText()
        return blocks
    }

    /// A header row followed by a delimiter row (`|---|:--:|`) with the same number of cells.
    private static func tableStart(header: String, delimiter: String) -> Table? {
        guard header.contains("|"), delimiter.contains("|") else { return nil }
        let names = cells(header)
        let marks = cells(delimiter)
        guard names.count == marks.count else { return nil }
        var alignments: [Alignment] = []
        for mark in marks {
            guard let alignment = alignment(mark) else { return nil }
            alignments.append(alignment)
        }
        return Table(header: names, alignments: alignments, rows: [])
    }

    private static func alignment(_ mark: String) -> Alignment? {
        let left = mark.hasPrefix(":")
        let right = mark.hasSuffix(":")
        let dashes = mark.dropFirst(left ? 1 : 0).dropLast(right && mark.count > 1 ? 1 : 0)
        guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
        switch (left, right) {
        case (true, true): return .center
        case (false, true): return .trailing
        default: return .leading
        }
    }

    private static func isBodyRow(_ line: String) -> Bool {
        line.contains("|") && !line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Cells between unescaped pipes; the outer pipes are optional and `\|` is a literal pipe.
    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for char in row {
            if escaped {
                cell.append(char == "|" ? "|" : "\\\(char)")
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(char)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func fitted(_ cells: [String], to count: Int) -> [String] {
        Array(cells.prefix(count)) + Array(repeating: "", count: max(0, count - cells.count))
    }
}
