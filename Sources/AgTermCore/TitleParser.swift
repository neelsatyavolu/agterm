import Foundation

/// What the terminal title says about the program running in it.
public enum TitleActivity: Equatable, Sendable {
    /// A spinner glyph leads the title while the agent works.
    case working
    /// The agent's idle marker leads the title (Claude Code's `✳`).
    case idle
    /// The agent says in its title that it waits for your answer (Grok's `⚠ Action Required`).
    case waiting
    /// A plain title with no agent marker.
    case unknown
}

public struct ParsedTitle: Equatable, Sendable {
    public let topic: String
    public let activity: TitleActivity

    public init(topic: String, activity: TitleActivity) {
        self.topic = topic
        self.activity = activity
    }
}

/// Agent CLIs put a status glyph in front of the topic in the OSC title. Claude Code 2.1.310
/// writes `✳ Fix login bug` when idle and cycles `◐`/`◑` while working; older builds and
/// other CLIs spin braille dots. Grok 1.0.73 ends every title with its name and has no idle
/// glyph: `⠋ - Thinking - Fix login bug - grok` while working, `Fix login bug - grok` when idle,
/// and `⚠ Action Required - …` in front when it waits for an answer.
public enum TitleParser {
    private static let idleMarkers: Set<Character> = ["✳"]
    private static let grokName = "grok"
    private static let grokSuffix = " - grok"
    private static let grokWaiting = "⚠ Action Required"
    private static let workingRanges: [ClosedRange<UInt32>] = [
        0x25D0...0x25D3, // ◐ ◑ ◒ ◓
        0x2800...0x28FF, // braille spinners
    ]

    public static func parse(_ raw: String) -> ParsedTitle {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return ParsedTitle(topic: "", activity: .unknown) }
        if isGrok(trimmed), trimmed.hasPrefix(grokWaiting) {
            let rest = trimmed.dropFirst(grokWaiting.count).drop { $0 == " " || $0 == "-" }
            return ParsedTitle(topic: parse(String(rest)).topic, activity: .waiting)
        }

        let activity: TitleActivity
        if idleMarkers.contains(first) {
            activity = .idle
        } else if let scalar = first.unicodeScalars.first, workingRanges.contains(where: { $0.contains(scalar.value) }) {
            activity = .working
        } else if isGrok(trimmed) {
            // Without its spinner, Grok's title means it's idle; its output then (a late topic,
            // a redraw) isn't work.
            return ParsedTitle(topic: droppingGrok(trimmed), activity: .idle)
        } else {
            return ParsedTitle(topic: droppingStatus(trimmed), activity: .unknown)
        }
        let topic = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        return ParsedTitle(topic: droppingGrok(droppingStatus(topic)), activity: activity)
    }

    /// True for titles that say when the agent needs you (Grok's). Such an agent's bell isn't a
    /// question: Grok also rings it when a turn ends while you're in another tab.
    public static func reportsWaiting(_ raw: String) -> Bool {
        isGrok(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether a title event says something: a new title, or Grok repeating its working title.
    /// Grok sends it again every couple of seconds while it works, but its spinner stops moving
    /// during a long command, so the repeat is the only sign it hasn't finished.
    public static func isNews(_ raw: String, previous: String) -> Bool {
        raw != previous || (reportsWaiting(raw) && parse(raw).activity == .working)
    }

    private static func isGrok(_ trimmed: String) -> Bool {
        trimmed == grokName || trimmed.hasSuffix(grokSuffix)
    }

    /// `Fix login bug - grok` → `Fix login bug`; a bare `grok` has no topic yet.
    private static func droppingGrok(_ topic: String) -> String {
        if topic == grokName { return "" }
        return topic.hasSuffix(grokSuffix) ? String(topic.dropLast(grokSuffix.count)) : topic
    }

    /// Grok puts its status between dashes before the topic: `- Thinking - Fix login bug`.
    private static func droppingStatus(_ topic: String) -> String {
        guard topic.hasPrefix("- "), let end = topic.range(of: " - ", range: topic.index(topic.startIndex, offsetBy: 2)..<topic.endIndex)
        else { return topic }
        return topic[end.upperBound...].trimmingCharacters(in: .whitespaces)
    }
}
