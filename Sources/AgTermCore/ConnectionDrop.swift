import Foundation

/// Claude Code ending a turn because the API never answered: no internet, DNS, Wi-Fi changing,
/// the Mac sleeping mid-response. Saying "continue" once the connection is back finishes the turn.
public enum ConnectionDrop {
    public struct Drop: Equatable, Sendable {
        public let message: String
        public let timestamp: Date

        public init(message: String, timestamp: Date) {
            self.message = message
            self.timestamp = timestamp
        }
    }

    /// The turn's last record is a synthetic assistant message,
    /// `{"type":"assistant","isApiErrorMessage":true,"error":"server_error",…}` with no
    /// `apiErrorStatus`, and text like "API Error: Can't reach the API server — check your internet
    /// or DNS (ENOTFOUND)" or "API Error: Connection lost mid-response". Errors the API answered with
    /// a status (500, 408, usage limits, billing) aren't drops. Subagents' copies don't count.
    public static func claude(line: String) -> Drop? {
        guard line.contains("isApiErrorMessage"), let record = LimitDetector.object(line),
              record["type"] as? String == "assistant", record["isSidechain"] as? Bool != true,
              record["isApiErrorMessage"] as? Bool == true, record["error"] as? String == "server_error",
              record["apiErrorStatus"] == nil || record["apiErrorStatus"] is NSNull,
              let timestamp = LimitDetector.timestamp(record) else { return nil }
        let content = (record["message"] as? [String: Any])?["content"] as? [[String: Any]]
        return Drop(message: content?.first?["text"] as? String ?? "Connection lost", timestamp: timestamp)
    }

    /// A message from you or a reply in the main conversation: whatever dropped before is over.
    static func movedOn(line: String) -> Bool {
        guard line.contains(#""type":"user""#) || line.contains(#""type":"assistant""#),
              let record = LimitDetector.object(line), record["isSidechain"] as? Bool != true,
              record["isApiErrorMessage"] as? Bool != true else { return false }
        return record["type"] as? String == "user" || record["type"] as? String == "assistant"
    }

    /// The drop still waiting for a resume after reading `lines`, starting from `pending`.
    /// Drops from before `since` (an earlier run of the agent) are ignored.
    public static func fold(_ lines: [String], pending: Drop?, since: Date) -> Drop? {
        lines.reduce(pending) { current, line in
            if let drop = claude(line: line) { return drop.timestamp > since ? drop : current }
            return current != nil && movedOn(line: line) ? nil : current
        }
    }
}
