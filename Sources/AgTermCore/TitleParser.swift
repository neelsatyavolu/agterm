import Foundation

/// What the terminal title says about the program running in it.
public enum TitleActivity: Equatable, Sendable {
    /// A spinner glyph leads the title while the agent works.
    case working
    /// The agent's idle marker leads the title (Claude Code's `✳`).
    case idle
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
/// glyph: `⠋ - Thinking - Fix login bug - grok` while working, `Fix login bug - grok` when idle.
public enum TitleParser {
    private static let idleMarkers: Set<Character> = ["✳"]
    private static let grokName = "grok"
    private static let grokSuffix = " - grok"
    private static let workingRanges: [ClosedRange<UInt32>] = [
        0x25D0...0x25D3, // ◐ ◑ ◒ ◓
        0x2800...0x28FF, // braille spinners
    ]

    public static func parse(_ raw: String) -> ParsedTitle {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return ParsedTitle(topic: "", activity: .unknown) }

        let activity: TitleActivity
        if idleMarkers.contains(first) {
            activity = .idle
        } else if let scalar = first.unicodeScalars.first, workingRanges.contains(where: { $0.contains(scalar.value) }) {
            activity = .working
        } else if trimmed == grokName || trimmed.hasSuffix(grokSuffix) {
            // Without its spinner, Grok's title means it's idle; its output then (a late topic,
            // a redraw) isn't work.
            return ParsedTitle(topic: droppingGrok(trimmed), activity: .idle)
        } else {
            return ParsedTitle(topic: droppingStatus(trimmed), activity: .unknown)
        }
        let topic = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        return ParsedTitle(topic: droppingGrok(droppingStatus(topic)), activity: activity)
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
