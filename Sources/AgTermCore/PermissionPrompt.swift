import Foundation

/// Spots an agent waiting for you to pick an answer, from the bottom of its screen. Claude Code
/// doesn't ring the bell for permission prompts, so the screen is the only sign.
///
/// Recorded shapes (Claude Code 2.1.310, Codex 0.163):
///
///     Do you want to proceed?            Hooks need review
///     ❯ 1. Yes                           › 1. Review hooks
///       2. No                              2. Trust all and continue
///     Esc to cancel · Tab to amend         enter confirm · esc skip
public enum PermissionPrompt {
    /// How far up from the bottom to look, in non-blank lines.
    static let window = 15
    private static let cursors: Set<Character> = ["❯", "›"]
    private static let borders = CharacterSet(charactersIn: "│┃║|").union(.whitespaces)

    /// True when a numbered choice sits under a selection cursor, next to a question or an Esc hint.
    public static func isVisible(_ lines: [String]) -> Bool {
        let tail = lines.map { $0.trimmingCharacters(in: borders) }.filter { !$0.isEmpty }.suffix(window)
        let choosing = tail.contains { line in
            guard let first = line.first, cursors.contains(first) else { return false }
            let rest = line.dropFirst().drop { $0 == " " }
            return rest.prefix { $0.isNumber }.count > 0 && rest.drop { $0.isNumber }.hasPrefix(". ")
        }
        guard choosing else { return false }
        return tail.contains { line in
            let lower = line.lowercased()
            // "esc to interrupt" is a working agent's hint, not a question.
            return line.hasSuffix("?") || (lower.contains("esc to") && !lower.contains("interrupt"))
                || lower.contains("esc skip") || lower.contains("esc cancel")
        }
    }
}
