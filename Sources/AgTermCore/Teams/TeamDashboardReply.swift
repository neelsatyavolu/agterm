import Foundation

extension TeamDashboard {
    /// Why a dashboard request failed, in words the window can show.
    public enum Failure: Error, Equatable, LocalizedError {
        /// The service no longer accepts this Mac's sign-in.
        case signedOut
        /// Not (or no longer) on this team.
        case notMember
        /// The service said no; its own sentence.
        case refused(String)
        case unavailable
        case unexpected
        /// No connection.
        case offline

        public var errorDescription: String? {
            switch self {
            case .signedOut: "agmux Teams no longer accepts this Mac's sign-in. Sign in again in Settings → Teams & Phone."
            case .notMember: "You're not on this team anymore."
            case .refused(let message): message
            case .unavailable: "agmux Teams is unavailable. Try again later."
            case .unexpected: "agmux Teams sent an unexpected reply."
            case .offline: "agmux Teams couldn't be reached."
            }
        }
    }

    /// The `data` of a teams-service `{ok, data, error}` reply.
    public static func unwrap<T: Decodable>(status: Int, body: Data) throws -> T {
        let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = (envelope?["error"] as? String).flatMap { $0.isEmpty || $0.count > 300 ? nil : $0 }
        switch status {
        case 401: throw Failure.signedOut
        case 404: throw Failure.notMember
        case 500...599: throw Failure.unavailable
        case 200..<300: break
        default: throw message.map(Failure.refused) ?? Failure.unexpected
        }
        guard let envelope else { throw Failure.unexpected }
        guard envelope["ok"] as? Bool == true, let data = envelope["data"] else {
            throw message.map(Failure.refused) ?? Failure.unexpected
        }
        guard let json = try? JSONSerialization.data(withJSONObject: data, options: [.fragmentsAllowed]),
              let value = try? JSONDecoder().decode(T.self, from: json) else { throw Failure.unexpected }
        return value
    }

    // MARK: Cache

    /// The last reply for each team and range, kept so the window opens with numbers (or shows
    /// them while offline) before a fetch finishes.
    public struct Cache: Codable, Equatable, Sendable {
        public struct Entry<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
            public var value: Value
            public var fetchedAt: Date
        }

        public var teams: Entry<TeamList>?
        private var overviews: [String: Entry<Overview>] = [:]

        public init() {}

        public func overview(team: String, range: Range) -> Entry<Overview>? { overviews[Self.key(team, range)] }

        public mutating func store(_ overview: Overview, team: String, range: Range, at date: Date) {
            overviews[Self.key(team, range)] = Entry(value: overview, fetchedAt: date)
        }

        public mutating func store(_ list: TeamList, at date: Date) {
            teams = Entry(value: list, fetchedAt: date)
            // Forget teams you've left.
            let ids = Set(list.teams.map(\.id))
            overviews = overviews.filter { ids.contains(String($0.key.split(separator: "|").first ?? "")) }
        }

        private static func key(_ team: String, _ range: Range) -> String { "\(team)|\(range.rawValue)" }
    }

    // MARK: Formatting

    public static func tokens(_ n: Double) -> String {
        let n = max(0, n)
        switch n {
        case 1e9...: return String(format: "%.1fB", n / 1e9)
        case 1e6...: return String(format: "%.1fM", n / 1e6)
        case 1e4...: return String(format: "%.1fk", n / 1e3)
        default: return grouped(n.rounded())
        }
    }

    public static func money(_ n: Double) -> String {
        if n <= 0 { return "$0" }
        if n >= 1000 { return "$" + grouped(n.rounded()) }
        return String(format: "$%.2f", n)
    }

    public static func percent(_ n: Double) -> String { "\(Int((n * 100).rounded()))%" }

    public static func hours(_ n: Double) -> String { String(format: "%.1fh", max(0, n)) }

    public static func count(_ n: Double) -> String { grouped(n.rounded()) }

    /// "+25%" or "−10%" against the previous range.
    public static func delta(_ n: Double?) -> String? {
        guard let n, n.isFinite else { return nil }
        let pct = Int((n * 100).rounded())
        return pct >= 0 ? "+\(pct)%" : "−\(-pct)%"
    }

    private static func grouped(_ n: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: n)) ?? String(Int(n))
    }

    /// The service's timestamps: SQLite's "2026-11-08 09:00:00" (UTC) or ISO 8601.
    public static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        let sqlite = DateFormatter()
        sqlite.locale = Locale(identifier: "en_US_POSIX")
        sqlite.timeZone = TimeZone(identifier: "UTC")
        sqlite.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return sqlite.date(from: raw)
    }

    /// Readable names for the providers the service reports.
    public static func providerName(_ key: String) -> String {
        switch key.lowercased() {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "grok": "Grok"
        case "gemini": "Gemini"
        default: key.isEmpty ? "Other" : key.prefix(1).uppercased() + key.dropFirst()
        }
    }
}
