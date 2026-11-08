import Foundation

/// One prompt you sent in a tab and how it went, for the Session Timeline (modeled on agmux's
/// `ThreadTurn`). Agent tabs build these from the agent's transcript; shell tabs from the
/// commands marked in the terminal (OSC 133).
public struct SessionTimelineTurn: Equatable, Sendable {
    public enum Status: String, Sendable {
        case running, done, failed, cancelled
    }

    public var id: String
    /// The prompt as you typed it, with the agent's wrappers (system tags, `<user_query>`) removed.
    public var prompt: String
    public var status: Status
    /// Milliseconds since the Unix epoch; nil when the source has no time.
    public var startedAt: Int?
    /// The terminal row it starts on, counted from the top of the scrollback, when that's known
    /// up front (shell commands). Agent turns are found by searching for the prompt instead.
    public var row: Int?

    public init(id: String, prompt: String, status: Status, startedAt: Int? = nil, row: Int? = nil) {
        self.id = id
        self.prompt = prompt
        self.status = status
        self.startedAt = startedAt
        self.row = row
    }
}

/// Reads a transcript one line at a time, so a reader can feed it only the bytes appended since
/// last time.
public protocol SessionTimelineFeed {
    /// One line, without its newline.
    mutating func feed(_ line: String)
}

extension SessionTimelineFeed {
    /// Feeds every complete line in `chunk` and returns how many bytes that used: up to and
    /// including the last newline. A trailing partial line is left for the next chunk.
    public mutating func feed(chunk: Data) -> Int {
        guard let end = chunk.lastIndex(of: 0x0A) else { return 0 }
        let complete = chunk[chunk.startIndex...end]
        for piece in complete.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
            let trimmed = piece.last == 0x0D ? piece.dropLast() : piece
            feed(String(decoding: trimmed, as: UTF8.self))
        }
        return complete.count
    }
}

public enum SessionTimelineFormat {
    /// agmux's `relativeTime`: "now" under 45 s, then minutes, hours and days.
    public static func relative(_ startedAt: Int?, now: Date = Date()) -> String {
        guard let startedAt, startedAt > 0 else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince1970) - startedAt / 1000)
        if seconds < 45 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    /// The prompt on one line, for a row that has room for a line or two.
    public static func oneLine(_ prompt: String) -> String {
        prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// agmux `cleanTimelinePrompt`: Grok wraps what you typed in `<user_query>…</user_query>`.
    public static func cleanPrompt(_ text: String) -> String {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = raw.range(of: "<user_query>", options: .caseInsensitive) else { return raw }
        let body = raw[open.upperBound...]
        let inner = body.range(of: "</user_query>", options: .caseInsensitive).map { body[..<$0.lowerBound] } ?? body
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
