import Foundation

/// Timestamp handling shared by the Teams readers and the aggregator.
///
/// Instants are compared as whole microseconds so span arithmetic never picks
/// up floating-point drift (Date stores seconds as a Double).
public enum TeamsTime {
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private static let timestampPattern = try? NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})([Tt ])(\d{2}):(\d{2}):(\d{2})(\.\d+)?([Zz]|[+-]\d{2}:\d{2})?$"#)

    /// Parses the timestamps provider logs use: RFC 3339 (`2026-07-29T14:00:00.123Z`,
    /// `+09:00` offsets) or SQLite's `datetime('now')` form (`2026-07-29 14:00:00`, UTC).
    public static func parse(_ raw: String) -> Date? {
        guard let regex = timestampPattern,
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { return nil }
        func group(_ i: Int) -> String? {
            guard let range = Range(match.range(at: i), in: raw) else { return nil }
            return String(raw[range])
        }
        let fields = [1, 2, 3, 5, 6, 7].compactMap { group($0).flatMap { Int($0) } }
        guard fields.count == 6 else { return nil }
        let (year, month, day, hour, minute, second) = (fields[0], fields[1], fields[2], fields[3], fields[4], fields[5])
        let fraction = group(8)
        let offset = group(9)
        // Without an offset only the plain SQLite form is accepted.
        if offset == nil, group(4) != " " || fraction != nil { return nil }
        guard (1...12).contains(month), (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second),
              let days = utcCalendar.range(of: .day, in: .month,
                                           for: utcCalendar.date(from: DateComponents(year: year, month: month)) ?? .distantPast),
              days.contains(day),
              let midnight = utcCalendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let micros = fraction.map { fractionMicros($0) } ?? 0
        let offsetSeconds = offset.map(offsetSeconds) ?? 0
        let wholeSeconds = Int(midnight.timeIntervalSince1970) + hour * 3600 + minute * 60 + second - offsetSeconds
        return date(micros: Int64(wholeSeconds) * 1_000_000 + micros)
    }

    /// `YYYY-MM-DDTHH` in UTC, the server's bucket key.
    public static func hourKey(_ date: Date) -> String {
        let parts = utcCalendar.dateComponents([.year, .month, .day, .hour], from: hourFloor(date))
        return String(format: "%04d-%02d-%02dT%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0)
    }

    static func micros(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    static func date(micros: Int64) -> Date {
        Date(timeIntervalSince1970: Double(micros) / 1_000_000)
    }

    static func hourFloor(_ date: Date) -> Date {
        let hour: Int64 = 3_600_000_000
        let us = micros(date)
        return self.date(micros: us - ((us % hour) + hour) % hour)
    }

    /// Rust `event_timestamp`: a string timestamp, or a numeric epoch in seconds
    /// (or milliseconds when the number is too large to be seconds).
    static func eventTimestamp(_ row: JSONValue) -> Date? {
        guard let value = row["timestamp"] else { return nil }
        if let text = value.string { return parse(text) }
        let raw = value.int ?? value.number.map { Int($0) }
        guard let n = raw else { return nil }
        let seconds = n > 10_000_000_000 ? n / 1000 : n
        return Date(timeIntervalSince1970: Double(seconds))
    }

    private static func fractionMicros(_ text: String) -> Int64 {
        let digits = String(text.dropFirst().prefix(6))
        let padded = digits + String(repeating: "0", count: 6 - digits.count)
        return Int64(padded) ?? 0
    }

    private static func offsetSeconds(_ text: String) -> Int {
        guard text.count == 6, let hours = Int(text.dropFirst().prefix(2)), let minutes = Int(text.suffix(2)) else { return 0 }
        let sign = text.hasPrefix("-") ? -1 : 1
        return sign * (hours * 3600 + minutes * 60)
    }
}
