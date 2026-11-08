import Foundation

/// The short figures a tab shows for its agent: "$1.24", "38k tokens", "12m".
public enum UsageText {
    /// Nil until something was spent. A total missing some turns' prices reads "$1.24+".
    public static func cost(_ usd: Double, incomplete: Bool) -> String? {
        guard usd.isFinite, usd >= 0.005 else { return nil }
        return String(format: "$%.2f", usd) + (incomplete ? "+" : "")
    }

    /// Nil for none; "940 tokens", "38k tokens", "1.2M tokens".
    public static func tokens(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        if count < 1000 { return "\(count) tokens" }
        if count < 1_000_000 { return "\(Int((Double(count) / 1000).rounded()))k tokens" }
        return String(format: "%.1fM tokens", Double(count) / 1_000_000)
    }

    /// How long the agent has run: "<1m", "12m", "2h 5m".
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
