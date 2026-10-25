import Foundation

// Small Rust/serde_json equivalents the timeline port depends on, so string
// handling matches agmux byte for byte.

extension JSONValue {
    /// Compact text matching serde_json's `Value::to_string()`: object keys in
    /// byte order (its default `BTreeMap`), no spaces, serde's string escapes.
    var serdeString: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let n): return String(n)
        case .double(let d):
            if d == d.rounded(), abs(d) < 1e16 { return String(format: "%.1f", d) }
            return d.description.replacingOccurrences(of: "e+", with: "e")
        case .string(let s): return serdeQuoted(s)
        case .array(let items): return "[" + items.map(\.serdeString).joined(separator: ",") + "]"
        case .object(let fields):
            let pairs = fields.keys.sorted(by: byteLess).map { key in
                serdeQuoted(key) + ":" + (fields[key]?.serdeString ?? "null")
            }
            return "{" + pairs.joined(separator: ",") + "}"
        }
    }

    /// The first of `keys` that is present (even as null), like a chain of
    /// `get(a).or_else(|| get(b))`.
    func firstPresent(_ keys: [String]) -> JSONValue? {
        for key in keys {
            if let value = self[key] { return value }
        }
        return nil
    }

    /// agmux `json_str`: the first key holding a non-empty string.
    func firstNonEmptyString(_ keys: [String]) -> String? {
        for key in keys {
            if let text = self[key]?.string, !text.isEmpty { return text }
        }
        return nil
    }
}

private func serdeQuoted(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

extension String {
    /// Rust `str::trim` (Unicode White_Space on both ends).
    var rustTrimmed: String { rustTrimStart.rustTrimEnd }

    /// Rust `str::trim_start`.
    var rustTrimStart: String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }) else { return "" }
        return String(scalars[first...])
    }

    /// Rust `str::trim_end`.
    var rustTrimEnd: String {
        let scalars = unicodeScalars
        guard let last = scalars.lastIndex(where: { !$0.properties.isWhitespace }) else { return "" }
        return String(scalars[...last])
    }

    var isBlank: Bool { rustTrimmed.isEmpty }

    /// Byte-wise `starts_with` (Swift's `hasPrefix` compares grapheme clusters,
    /// so `"+\u{301}"` would not start with `"+"`).
    func startsWith(_ prefix: String) -> Bool { utf8.starts(with: prefix.utf8) }

    /// Byte-wise `ends_with`.
    func endsWith(_ suffix: String) -> Bool { utf8.reversed().starts(with: suffix.utf8.reversed()) }

    /// Byte-wise `contains`.
    func containsBytes(_ needle: String) -> Bool { range(of: needle, options: .literal) != nil }
}

/// agmux `truncate`: at most `max` chars (Unicode scalars, as Rust `chars()`),
/// with an ellipsis when cut.
func timelineTruncate(_ text: String, _ max: Int) -> String {
    let scalars = text.unicodeScalars
    guard scalars.count > max else { return text }
    return String(String.UnicodeScalarView(scalars.prefix(max))) + "…"
}

/// agmux `parse_log_ts`: SQLite `YYYY-MM-DD HH:MM:SS[.mmm]` (UTC) or RFC 3339,
/// in epoch milliseconds; 0 when unparseable.
func parseLogTimestamp(_ text: String) -> Int {
    var scanner = TimestampScanner(Array(text.utf8))
    return scanner.parse() ?? 0
}

private struct TimestampScanner {
    let bytes: [UInt8]
    var i = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func parse() -> Int? {
        guard let year = digits(4), byte("-"), let month = digits(2), byte("-"), let day = digits(2),
              i < bytes.count else { return nil }
        let separator = bytes[i]
        guard separator == UInt8(ascii: "T") || separator == UInt8(ascii: "t") || separator == UInt8(ascii: " ") else { return nil }
        i += 1
        guard let hour = digits(2), byte(":"), let minute = digits(2), byte(":"), let second = digits(2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        var millis = 0
        var fractionDigits = 0
        if byte(".") {
            var scale = 100
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) {
                millis += Int(bytes[i] - 0x30) * scale
                scale /= 10
                fractionDigits += 1
                i += 1
            }
            guard fractionDigits > 0 else { return nil }
        }
        let base = (daysFromCivil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second) * 1_000 + millis
        if i == bytes.count {
            // Naive SQLite forms only (space separator, none or exactly 3 fraction digits).
            guard separator == UInt8(ascii: " "), fractionDigits == 0 || fractionDigits == 3 else { return nil }
            return base
        }
        if byte("Z") || byte("z") { return i == bytes.count ? base : nil }
        let sign: Int
        if byte("+") { sign = 1 } else if byte("-") { sign = -1 } else { return nil }
        guard let offH = digits(2), byte(":"), let offM = digits(2), i == bytes.count else { return nil }
        return base - sign * (offH * 3_600 + offM * 60) * 1_000
    }

    mutating func digits(_ count: Int) -> Int? {
        guard i + count <= bytes.count else { return nil }
        var value = 0
        for b in bytes[i..<(i + count)] {
            guard (0x30...0x39).contains(b) else { return nil }
            value = value * 10 + Int(b - 0x30)
        }
        i += count
        return value
    }

    mutating func byte(_ char: Unicode.Scalar) -> Bool {
        guard i < bytes.count, bytes[i] == UInt8(ascii: char) else { return false }
        i += 1
        return true
    }

    func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
