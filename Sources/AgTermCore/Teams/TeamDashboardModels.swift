import Foundation

/// What agmux Teams' dashboard routes send (`GET /api/teams`, `…/overview`, `…/members/:id/detail`,
/// `…/me`), for agterm's Teams window. Every field is optional on the wire: a missing or mistyped
/// one falls back to a default, so an older or newer server never breaks the window.
public enum TeamDashboard {
    public enum Range: String, CaseIterable, Codable, Sendable {
        case week = "7d", twoWeeks = "14d", month = "30d", quarter = "90d"

        public var title: String {
            switch self {
            case .week: "7 days"
            case .twoWeeks: "14 days"
            case .month: "30 days"
            case .quarter: "90 days"
            }
        }
    }

    public enum Role: String, Codable, Sendable {
        case owner, manager, employee

        /// Owners and managers see team totals and manage logins.
        public var isAdmin: Bool { self != .employee }
        public var title: String { rawValue.capitalized }
    }

    /// The whole team, a manager's own people, or (for employees) only yourself.
    public enum Scope: String, Codable, Sendable { case team, partial, `self` }

    // MARK: Team list

    public struct Team: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var slug: String
        public var name: String
        public var role: Role
        public var memberCount: Int
        public var lastUploadAt: String?
        public var staffPreview: Bool

        enum CodingKeys: String, CodingKey {
            case id, slug, name, role, memberCount = "member_count", lastUploadAt = "last_upload_at", staffPreview
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.get(.id, "")
            slug = c.get(.slug, "")
            name = c.get(.name, "Team")
            role = c.get(.role, .employee)
            memberCount = c.get(.memberCount, 0)
            lastUploadAt = c.opt(.lastUploadAt)
            staffPreview = c.get(.staffPreview, false)
        }
    }

    /// `GET /api/teams`. Staff previews (web only) and rows without an id are left out.
    public struct TeamList: Codable, Equatable, Sendable {
        public var teams: [Team]

        public init(teams: [Team]) { self.teams = teams }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            teams = c.list(.teams).filter { !$0.id.isEmpty && !$0.staffPreview }
        }

        enum CodingKeys: String, CodingKey { case teams }
    }

    // MARK: Numbers

    /// Server-computed totals (`aggregate.ts` `Totals`).
    public struct Totals: Codable, Equatable, Sendable {
        public var tokensIn = 0.0, tokensOut = 0.0, tokensCacheRead = 0.0, tokensCacheWrite = 0.0, tokensReasoning = 0.0
        public var tokens = 0.0
        public var cacheHitRate = 0.0
        public var costUsd = 0.0
        public var costIncomplete = true
        public var activeHours = 0.0
        public var afterHoursShare = 0.0, weekendShare = 0.0
        public var sessions = 0.0, sessionsStarted = 0.0
        public var turns = 0.0, toolCalls = 0.0, peakConcurrent = 0.0
        public var daysWithData = 0.0
        public var toolMix: [String: Double] = [:]
        public var toolErrors = 0.0, toolsMeasured = 0.0
        /// Nil when nothing was measurable: shown as such, never as 0%.
        public var toolErrorRate: Double?
        public var filesChanged = 0.0, linesAdded = 0.0, linesRemoved = 0.0

        public init() {}

        enum CodingKeys: String, CodingKey {
            case tokensIn, tokensOut, tokensCacheRead, tokensCacheWrite, tokensReasoning, tokens, cacheHitRate, costUsd,
                 costIncomplete, activeHours, afterHoursShare, weekendShare, sessions, sessionsStarted, turns, toolCalls,
                 peakConcurrent, daysWithData, toolMix, toolErrors, toolsMeasured, toolErrorRate, filesChanged,
                 linesAdded, linesRemoved
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tokensIn = c.get(.tokensIn, 0); tokensOut = c.get(.tokensOut, 0)
            tokensCacheRead = c.get(.tokensCacheRead, 0); tokensCacheWrite = c.get(.tokensCacheWrite, 0)
            tokensReasoning = c.get(.tokensReasoning, 0); tokens = c.get(.tokens, 0)
            cacheHitRate = c.get(.cacheHitRate, 0); costUsd = c.get(.costUsd, 0)
            costIncomplete = c.get(.costIncomplete, true); activeHours = c.get(.activeHours, 0)
            afterHoursShare = c.get(.afterHoursShare, 0); weekendShare = c.get(.weekendShare, 0)
            sessions = c.get(.sessions, 0); sessionsStarted = c.get(.sessionsStarted, 0)
            turns = c.get(.turns, 0); toolCalls = c.get(.toolCalls, 0); peakConcurrent = c.get(.peakConcurrent, 0)
            daysWithData = c.get(.daysWithData, 0); toolMix = c.get(.toolMix, [:])
            toolErrors = c.get(.toolErrors, 0); toolsMeasured = c.get(.toolsMeasured, 0)
            toolErrorRate = c.opt(.toolErrorRate)
            filesChanged = c.get(.filesChanged, 0); linesAdded = c.get(.linesAdded, 0); linesRemoved = c.get(.linesRemoved, 0)
        }
    }

    /// Change against the previous range of the same length, as a fraction; nil when there's nothing to compare.
    public struct Deltas: Codable, Equatable, Sendable {
        public var tokens: Double?, costUsd: Double?, activeHours: Double?, sessions: Double?

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tokens = c.opt(.tokens); costUsd = c.opt(.costUsd); activeHours = c.opt(.activeHours); sessions = c.opt(.sessions)
        }

        enum CodingKeys: String, CodingKey { case tokens, costUsd, activeHours, sessions }
    }

    public struct Day: Codable, Equatable, Sendable, Identifiable {
        public var date: String
        public var label: String
        public var full: String
        public var tokens: Double
        public var activeHours: Double
        public var sessions: Double
        public var peakConcurrent: Double
        public var weekend: Bool
        public var hasData: Bool
        public var id: String { date }

        enum CodingKeys: String, CodingKey { case date, label, full, tokens, activeHours, sessions, peakConcurrent, weekend, hasData }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = c.get(.date, ""); label = c.get(.label, ""); full = c.get(.full, "")
            tokens = c.get(.tokens, 0); activeHours = c.get(.activeHours, 0); sessions = c.get(.sessions, 0)
            peakConcurrent = c.get(.peakConcurrent, 0); weekend = c.get(.weekend, false); hasData = c.get(.hasData, false)
        }
    }

    /// One provider's or model's share of tokens and of active time.
    public struct Mix: Codable, Equatable, Sendable, Identifiable {
        public var key: String
        public var tokens: Double
        public var share: Double
        public var timeShare: Double
        public var id: String { key }

        enum CodingKeys: String, CodingKey { case key, tokens, share, timeShare }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = c.get(.key, "other"); tokens = c.get(.tokens, 0); share = c.get(.share, 0); timeShare = c.get(.timeShare, 0)
        }
    }

    public struct Project: Codable, Equatable, Sendable, Identifiable {
        public var projectKey: String
        public var activeHours: Double
        public var tokens: Double
        public var sessions: Double
        public var id: String { projectKey }

        enum CodingKeys: String, CodingKey { case projectKey, activeHours, tokens, sessions }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            projectKey = c.get(.projectKey, "—"); activeHours = c.get(.activeHours, 0)
            tokens = c.get(.tokens, 0); sessions = c.get(.sessions, 0)
        }
    }

    public struct Flags: Codable, Equatable, Sendable {
        public var afterHoursShare = 0.0, afterHoursSharePrev = 0.0, weekendShare = 0.0
        public var idleDays = 0

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            afterHoursShare = c.get(.afterHoursShare, 0); afterHoursSharePrev = c.get(.afterHoursSharePrev, 0)
            weekendShare = c.get(.weekendShare, 0); idleDays = c.get(.idleDays, 0)
        }

        enum CodingKeys: String, CodingKey { case afterHoursShare, afterHoursSharePrev, weekendShare, idleDays }
    }

    /// This month's estimated spend against the team's budget, with a straight-line month-end projection.
    public struct Budget: Codable, Equatable, Sendable {
        public var month: String
        public var monthlyUsd: Double
        public var spendUsd: Double
        public var usedShare: Double
        public var projectedUsd: Double
        public var projectedShare: Double
        public var daysElapsed: Int
        public var daysInMonth: Int
        public var onTrackToExceed: Bool
        public var costIncomplete: Bool

        enum CodingKeys: String, CodingKey {
            case month, monthlyUsd, spendUsd, usedShare, projectedUsd, projectedShare, daysElapsed, daysInMonth, onTrackToExceed, costIncomplete
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            month = c.get(.month, ""); monthlyUsd = c.get(.monthlyUsd, 0); spendUsd = c.get(.spendUsd, 0)
            usedShare = c.get(.usedShare, 0); projectedUsd = c.get(.projectedUsd, 0); projectedShare = c.get(.projectedShare, 0)
            daysElapsed = c.get(.daysElapsed, 0); daysInMonth = c.get(.daysInMonth, 30)
            onTrackToExceed = c.get(.onTrackToExceed, false); costIncomplete = c.get(.costIncomplete, true)
        }
    }
}

// MARK: Tolerant decoding

extension KeyedDecodingContainer {
    /// The value, or `fallback` when it's missing, null or of another type.
    func get<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    func opt<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// An array, skipping elements that aren't objects of the right shape.
    func list<T: Decodable>(_ key: Key) -> [T] {
        (get(key, [Lossy<T>]())).compactMap(\.value)
    }
}

private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
