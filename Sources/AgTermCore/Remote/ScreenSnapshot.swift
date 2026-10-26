import Foundation

/// Text that shares one set of colors and styles. Defaults are left out of the JSON to keep
/// frames small: `f`/`b` are `CellColor.wire`, `s` is `CellStyle.rawValue`.
public struct ScreenRun: Codable, Equatable, Sendable {
    public var t: String
    public var f: Int?
    public var b: Int?
    public var s: UInt8?

    public init(t: String, f: Int? = nil, b: Int? = nil, s: UInt8? = nil) {
        self.t = t
        self.f = f
        self.b = b
        self.s = s == 0 ? nil : s
    }

    public var fg: CellColor { CellColor(wire: f) }
    public var bg: CellColor { CellColor(wire: b) }
    public var style: CellStyle { CellStyle(rawValue: s ?? 0) }
}

/// A tab's screen with colors, plus some scrollback above it, for the phone to draw.
public struct ScreenSnapshot: Codable, Equatable, Sendable {
    public var cols: Int
    /// Visible rows; they are the last `rows` entries of `lines`.
    public var rows: Int
    public var lines: [[ScreenRun]]
    /// Index into `lines`, and column, of the cursor when it's shown.
    public var cursorRow: Int?
    public var cursorCol: Int?
    /// `ThemePalette.id` of the Mac's theme, so the phone uses the same colors.
    public var theme: String

    public init(cols: Int, rows: Int, lines: [[ScreenRun]], cursorRow: Int?, cursorCol: Int?, theme: String) {
        self.cols = cols
        self.rows = rows
        self.lines = lines
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
        self.theme = theme
    }

    /// Drops the oldest lines until the encoded snapshot fits in `bytes`.
    public mutating func trim(toBytes bytes: Int) {
        let encoder = JSONEncoder()
        while lines.count > 1, ((try? encoder.encode(self).count) ?? 0) > bytes {
            let drop = min(max(1, lines.count / 8), lines.count - 1)
            lines.removeFirst(drop)
            cursorRow = cursorRow.map { max(0, $0 - drop) }
        }
    }
}

/// Builds one line's runs cell by cell, merging neighbours with the same look and dropping
/// trailing blanks that have no background.
public struct ScreenLineBuilder {
    public private(set) var runs: [ScreenRun] = []
    /// Blank default cells not yet known to be followed by text.
    private var pendingBlanks = 0

    public init() {}

    public mutating func add(_ character: Character, fg: CellColor, bg: CellColor, style: CellStyle) {
        if character == " ", fg == .default, bg == .default, style.isEmpty {
            pendingBlanks += 1
            return
        }
        if pendingBlanks > 0 {
            append(String(repeating: " ", count: pendingBlanks), fg: .default, bg: .default, style: [])
            pendingBlanks = 0
        }
        append(String(character), fg: fg, bg: bg, style: style)
    }

    private mutating func append(_ text: String, fg: CellColor, bg: CellColor, style: CellStyle) {
        let run = ScreenRun(t: text, f: fg.wire, b: bg.wire, s: style.rawValue)
        if let last = runs.last, last.f == run.f, last.b == run.b, last.s == run.s {
            runs[runs.count - 1].t += text
        } else {
            runs.append(run)
        }
    }
}

extension CellColor {
    /// nil for the default color, 0–255 for palette colors, 0x1000000 + RGB for true color.
    public var wire: Int? {
        switch self {
        case .default: nil
        case .ansi(let n): Int(n)
        case let .rgb(r, g, b): 0x100_0000 + Int(r) << 16 + Int(g) << 8 + Int(b)
        }
    }

    public init(wire: Int?) {
        guard let wire else { self = .default; return }
        if wire < 256 {
            self = .ansi(UInt8(max(0, wire)))
        } else {
            let rgb = wire - 0x100_0000
            self = .rgb(UInt8((rgb >> 16) & 0xFF), UInt8((rgb >> 8) & 0xFF), UInt8(rgb & 0xFF))
        }
    }
}
