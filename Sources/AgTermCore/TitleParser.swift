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
/// other CLIs spin braille dots.
public enum TitleParser {
    private static let idleMarkers: Set<Character> = ["✳"]
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
        } else {
            return ParsedTitle(topic: trimmed, activity: .unknown)
        }
        let topic = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        return ParsedTitle(topic: topic, activity: activity)
    }
}
