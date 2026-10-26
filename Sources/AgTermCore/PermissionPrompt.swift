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
    /// Claude Code's, Codex's and Gemini CLI's marks for the highlighted answer.
    private static let cursors: Set<Character> = ["❯", "›", "●"]
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
                || lower.contains("esc skip") || lower.contains("esc cancel") || lower.contains("esc back")
        }
    }

    /// The question and its numbered answers, for the phone to show as buttons. Nil without a prompt.
    public static func read(_ lines: [String]) -> PromptInfo? {
        guard isVisible(lines) else { return nil }
        let trimmed = lines.map { $0.trimmingCharacters(in: borders) }
        // Where each tail line sits in `trimmed`, which keeps the blank lines between paragraphs.
        let rows = Array(trimmed.indices.filter { !trimmed[$0].isEmpty }.suffix(window))
        let tail = rows.map { trimmed[$0] }
        let parsed = tail.map(choice)
        guard let cursor = parsed.firstIndex(where: { $0?.selected == true }) else { return nil }
        // The answers are the run of consecutive numbers around the cursor; numbered output above is not.
        var first = cursor, last = cursor
        while first > 0, let above = parsed[first - 1], let here = parsed[first], Int(above.key) == Int(here.key)! - 1 {
            first -= 1
        }
        while last + 1 < parsed.count, let below = parsed[last + 1], let here = parsed[last], Int(below.key) == Int(here.key)! + 1 {
            last += 1
        }
        // The question is the nearest line above with a "?", up to it (Codex runs on after it),
        // or else the first line of the paragraph above the choices ("Hooks need review").
        let question = tail[..<first].last { $0.contains("?") && !$0.contains("? for shortcuts") }
            .map { String($0[...$0.firstIndex(of: "?")!]) }
            ?? heading(above: rows[first], in: trimmed, from: rows[0])
        return PromptInfo(question: question, choices: parsed[first...last].compactMap { $0 })
    }

    /// The top line of the paragraph just above `row`, not looking above `top`.
    private static func heading(above row: Int, in lines: [String], from top: Int) -> String? {
        var end = row - 1
        while end >= top, lines[end].isEmpty { end -= 1 }
        guard end >= top else { return nil }
        var start = end
        while start > top, !lines[start - 1].isEmpty { start -= 1 }
        return lines[start]
    }

    /// `❯ 2. No` or `2. No` as a choice; nil for any other line.
    private static func choice(_ line: String) -> PromptChoice? {
        var rest = Substring(line)
        let selected = rest.first.map(cursors.contains) ?? false
        if selected { rest = rest.dropFirst().drop { $0 == " " } }
        let digits = rest.prefix { $0.isNumber }
        // Up to three ASCII digits keeps the force unwraps and ±1 in read() safe ("½" and Int.max aren't answers).
        guard (1...3).contains(digits.count), digits.allSatisfy(\.isASCII), rest.dropFirst(digits.count).hasPrefix(". ")
        else { return nil }
        let label = rest.dropFirst(digits.count + 2).trimmingCharacters(in: .whitespaces)
        return PromptChoice(key: String(digits), label: label, selected: selected)
    }
}
