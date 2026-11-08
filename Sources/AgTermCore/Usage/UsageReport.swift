import Foundation

/// What the Usage window can show for a stretch of time.
public enum UsagePeriod: Int, CaseIterable, Sendable {
    case today, week, month

    /// Calendar days covered, today included.
    public var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }

    public var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        }
    }
}

/// Token, cost and session counts for some set of usage events.
public struct UsageTotals: Equatable, Sendable {
    public let tokensIn: Int
    public let tokensOut: Int
    public let cacheRead: Int
    public let cacheWrite: Int
    public let costUSD: Double
    /// Some events had no price, so `costUSD` is a lower bound.
    public let costIncomplete: Bool
    /// Sessions people started; subagent threads aren't counted.
    public let sessions: Int

    public static let zero = UsageTotals(tokensIn: 0, tokensOut: 0, cacheRead: 0, cacheWrite: 0,
                                         costUSD: 0, costIncomplete: false, sessions: 0)

    public init(tokensIn: Int, tokensOut: Int, cacheRead: Int, cacheWrite: Int,
                costUSD: Double, costIncomplete: Bool, sessions: Int) {
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.costUSD = costUSD
        self.costIncomplete = costIncomplete
        self.sessions = sessions
    }

    public var tokens: Int { tokensIn + tokensOut + cacheRead + cacheWrite }

    /// Totals of `events`, counting each `provider`/`sessionID` started by a person once.
    static func of<S: Sequence>(_ events: S) -> UsageTotals where S.Element == UsageEvent {
        var tokensIn = 0, tokensOut = 0, cacheRead = 0, cacheWrite = 0
        var cost = 0.0, incomplete = false
        var sessions = Set<String>()
        for e in events {
            tokensIn += e.tokensIn
            tokensOut += e.tokensOut
            cacheRead += e.cacheRead
            cacheWrite += e.cacheWrite
            cost += e.costUSD
            incomplete = incomplete || e.costIncomplete
            if !e.subagent, !e.isSubagentPath { sessions.insert(e.provider + "\u{0}" + e.sessionID) }
        }
        return UsageTotals(tokensIn: tokensIn, tokensOut: tokensOut, cacheRead: cacheRead, cacheWrite: cacheWrite,
                           costUSD: cost, costIncomplete: incomplete, sessions: sessions.count)
    }
}

/// One named row: a model or a project.
public struct UsageRow: Equatable, Sendable {
    public let name: String
    public let totals: UsageTotals
}

/// One local calendar day.
public struct UsageDay: Equatable, Sendable {
    /// Local midnight that starts the day.
    public let start: Date
    public let totals: UsageTotals
}

/// A period's totals, with its models and projects ranked by cost, then tokens.
public struct UsageSummary: Equatable, Sendable {
    public let totals: UsageTotals
    public let models: [UsageRow]
    public let projects: [UsageRow]

    static let empty = UsageSummary(totals: .zero, models: [], projects: [])
}

/// Usage over the last 30 days, built once from parsed transcript events.
public struct UsageReport: Equatable, Sendable {
    public static let dayCount = 30

    /// Oldest first; always `dayCount` days, the last one today.
    public let days: [UsageDay]
    private let summaries: [UsagePeriod: UsageSummary]

    public static let empty = UsageReport(days: [], summaries: [:])

    public func summary(_ period: UsagePeriod) -> UsageSummary { summaries[period] ?? .empty }

    /// Groups `events` by local day in `calendar`'s time zone. Claude requests that appear in
    /// several transcripts (forks, subagents) count once, as in Teams.
    public static func build(events: [UsageEvent], now: Date, calendar: Calendar) -> UsageReport {
        let today = calendar.startOfDay(for: now)
        let starts = (0..<dayCount).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        guard let first = starts.first else { return .empty }
        let kept = ClaudeTranscript.reconcile(events).filter { $0.at >= first && $0.at <= now }

        var byDay: [Date: [UsageEvent]] = [:]
        for e in kept { byDay[calendar.startOfDay(for: e.at), default: []].append(e) }
        let days = starts.map { UsageDay(start: $0, totals: .of(byDay[$0] ?? [])) }

        var summaries: [UsagePeriod: UsageSummary] = [:]
        for period in UsagePeriod.allCases {
            let from = starts[dayCount - period.days]
            let inPeriod = kept.filter { $0.at >= from }
            summaries[period] = UsageSummary(totals: .of(inPeriod),
                                             models: rows(inPeriod, by: \.model),
                                             projects: rows(inPeriod, by: \.projectKey))
        }
        return UsageReport(days: days, summaries: summaries)
    }

    private static func rows(_ events: [UsageEvent], by key: KeyPath<UsageEvent, String>) -> [UsageRow] {
        Dictionary(grouping: events) { $0[keyPath: key].isEmpty ? "Other" : $0[keyPath: key] }
            .map { UsageRow(name: $0.key, totals: .of($0.value)) }
            .sorted {
                if $0.totals.costUSD != $1.totals.costUSD { return $0.totals.costUSD > $1.totals.costUSD }
                if $0.totals.tokens != $1.totals.tokens { return $0.totals.tokens > $1.totals.tokens }
                return $0.name < $1.name
            }
    }
}
