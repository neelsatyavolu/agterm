import Foundation

/// An agent's own record that it just stopped at a usage limit.
public struct LimitHit: Equatable, Sendable {
    public let message: String
    /// When the agent wrote it (both CLIs stamp every record), so old or replayed records can be ignored.
    public let timestamp: Date?

    public init(message: String, timestamp: Date? = nil) {
        self.message = message
        self.timestamp = timestamp
    }
}

public enum LimitDetector {
    /// Claude Code writes a synthetic assistant message when a turn stops at a limit:
    /// `{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,…}`
    /// with text like "You've hit your weekly limit · resets 1am (America/Los_Angeles)".
    /// Subagents' copies (`isSidechain`) don't count; the main session gets its own.
    public static func claude(line: String) -> LimitHit? {
        guard line.contains("rate_limit"), let record = object(line),
              record["type"] as? String == "assistant", record["isSidechain"] as? Bool != true,
              record["error"] as? String == "rate_limit" || (record["isApiErrorMessage"] as? Bool == true && record["apiErrorStatus"] as? Int == 429)
        else { return nil }
        let content = (record["message"] as? [String: Any])?["content"] as? [[String: Any]]
        return LimitHit(message: content?.first?["text"] as? String ?? "Usage limit reached", timestamp: timestamp(record))
    }

    /// Codex rollouts: an `error` event about the usage limit, or a `token_count` whose rate
    /// limits say one was reached with no credits to fall back on.
    public static func codex(line: String) -> LimitHit? {
        guard line.contains("event_msg"), let record = object(line), record["type"] as? String == "event_msg",
              let payload = record["payload"] as? [String: Any] else { return nil }
        switch payload["type"] as? String {
        case "error":
            let message = payload["message"] as? String ?? ""
            let info = String(describing: payload["codex_error_info"] ?? "").lowercased()
            guard message.lowercased().contains("usage limit") || info.contains("usage_limit") || info.contains("usagelimit") else { return nil }
            return LimitHit(message: message.isEmpty ? "Usage limit reached" : message, timestamp: timestamp(record))
        case "token_count":
            guard let limits = (payload["rate_limits"] ?? (payload["info"] as? [String: Any])?["rate_limits"]) as? [String: Any],
                  let reached = limits["rate_limit_reached_type"] as? String, !reached.isEmpty else { return nil }
            let credits = limits["credits"] as? [String: Any]
            if credits?["has_credits"] as? Bool == true || credits?["unlimited"] as? Bool == true { return nil }
            return LimitHit(message: "Codex usage limit reached (\(reached))", timestamp: timestamp(record))
        default:
            return nil
        }
    }

    private static func timestamp(_ record: [String: Any]) -> Date? {
        guard let text = record["timestamp"] as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func object(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
}
