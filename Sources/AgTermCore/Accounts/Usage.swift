import Foundation

/// Agents whose logins agterm can switch between.
public enum AccountProvider: String, Codable, CaseIterable, Sendable {
    case claude, codex

    public var title: String { self == .claude ? "Claude Code" : "Codex" }
    /// The variable that points the CLI at a login's folder.
    public var homeVariable: String { self == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME" }
}

/// One usage limit, like the 5-hour or weekly window.
public struct UsageWindow: Codable, Equatable, Sendable {
    public let name: String
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(name: String, usedPercent: Double, resetsAt: Date?) {
        self.name = name
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// A login's usage at one moment.
public struct UsageReading: Codable, Equatable, Sendable {
    public var windows: [UsageWindow]
    public var plan: String?
    public var email: String?
    /// Codex: paid credits keep it going past its limits.
    public var hasCredits: Bool
    public var checkedAt: Date

    public init(windows: [UsageWindow], plan: String? = nil, email: String? = nil, hasCredits: Bool = false, checkedAt: Date) {
        self.windows = windows
        self.plan = plan
        self.email = email
        self.hasCredits = hasCredits
        self.checkedAt = checkedAt
    }

    /// Percent left in the tightest window, or nil with no windows.
    public var remainingPercent: Double? {
        windows.map { max(0, 100 - $0.usedPercent) }.min()
    }

    /// When a used-up window frees up again, or nil if nothing is used up now.
    public func exhaustedUntil(_ now: Date) -> Date? {
        guard !hasCredits else { return nil }
        let full = windows.filter { $0.usedPercent >= 100 && ($0.resetsAt.map { $0 > now } ?? true) }
        guard !full.isEmpty else { return nil }
        return full.compactMap(\.resetsAt).max() ?? now.addingTimeInterval(3600)
    }
}

public enum UsageParser {
    private static let claudeWindows: [(key: String, name: String)] = [
        ("five_hour", "5-hour"), ("seven_day", "Weekly"), ("seven_day_opus", "Weekly Opus"), ("seven_day_sonnet", "Weekly Sonnet"),
    ]

    /// Claude Code's `get_usage` control response (`rate_limits.<window>.{utilization, resets_at}`)
    /// plus the `initialize` response's account.
    public static func claude(usage: [String: Any], account: [String: Any]?, now: Date) -> UsageReading? {
        guard usage["rate_limits_available"] as? Bool != false, let limits = usage["rate_limits"] as? [String: Any] else { return nil }
        let windows = claudeWindows.compactMap { key, name -> UsageWindow? in
            guard let window = limits[key] as? [String: Any], let used = number(window["utilization"]) else { return nil }
            return UsageWindow(name: name, usedPercent: used, resetsAt: (window["resets_at"] as? String).flatMap(isoDate))
        }
        return UsageReading(windows: windows, plan: account?["subscriptionType"] as? String,
                            email: account?["email"] as? String, checkedAt: now)
    }

    /// Codex app-server `account/rateLimits/read` result (camelCase) or a rollout's
    /// `token_count.rate_limits` (snake_case).
    public static func codex(rateLimits: [String: Any], plan: String? = nil, email: String? = nil, now: Date) -> UsageReading {
        let limits = rateLimits["rateLimits"] as? [String: Any] ?? rateLimits
        let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
            guard let window = limits[key] as? [String: Any],
                  let used = number(window["usedPercent"] ?? window["used_percent"]) else { return nil }
            let minutes = number(window["windowDurationMins"] ?? window["window_minutes"]).map(Int.init)
            let reset = number(window["resetsAt"] ?? window["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            return UsageWindow(name: windowName(minutes: minutes), usedPercent: used, resetsAt: reset)
        }
        let credits = limits["credits"] as? [String: Any]
        let hasCredits = (credits?["hasCredits"] ?? credits?["has_credits"]) as? Bool == true
            || (credits?["unlimited"] as? Bool == true)
        let reportedPlan = (limits["planType"] ?? limits["plan_type"]) as? String
        return UsageReading(windows: windows, plan: (plan ?? reportedPlan).map(codexPlanName), email: email, hasCredits: hasCredits, checkedAt: now)
    }

    /// ChatGPT plan ids as people know them (prolite and pro are the 5x and 20x Pro tiers).
    public static func codexPlanName(_ id: String) -> String {
        let names = ["free": "Free", "go": "Go", "plus": "Plus", "prolite": "Pro 5x", "pro": "Pro 20x", "team": "Team",
                     "business": "Business", "enterprise": "Enterprise", "edu": "Edu"]
        return names[id.lowercased()] ?? id.prefix(1).uppercased() + id.dropFirst()
    }

    static func windowName(minutes: Int?) -> String {
        guard let minutes else { return "Limit" }
        if minutes <= 360 { return "\(max(1, minutes / 60))-hour" }
        if minutes == 10080 { return "Weekly" }
        return "\(minutes / 1440)-day"
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func isoDate(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
