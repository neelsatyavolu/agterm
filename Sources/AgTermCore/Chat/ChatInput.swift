import Foundation

/// What the chat's composer types into the agent's terminal, the way the phone remote does:
/// clear the line (⌃U), type the text, then press Enter after a short pause so the agent's
/// input box has taken the text in.
public enum ChatInput {
    public static let clearLine = "\u{15}"
    public static let enter = "\r"
    public static let escape = "\u{1b}"
    public static let backTab = "\u{1b}[Z"
    public static let tab = "\t"

    public enum Arrow: Character, Sendable { case up = "A", down = "B", right = "C", left = "D" }

    /// An arrow key as the terminal sends it: `ESC O A` when the agent turned on application
    /// cursor keys, else `ESC [ A`.
    public static func arrow(_ arrow: Arrow, applicationCursor: Bool) -> String {
        "\u{1b}" + (applicationCursor ? "O" : "[") + String(arrow.rawValue)
    }
    /// The pause between the text and Enter.
    public static let submitDelay: TimeInterval = 0.3
    /// The pause when images go too, so the agent has read them in first.
    public static let imageSubmitDelay: TimeInterval = 1.0

    /// The keys for a message, or nil when there's nothing to send. Several lines go as one
    /// bracketed paste when the terminal has it on; otherwise newlines would press Enter, so the
    /// lines are joined with spaces. Each image's path goes first as a paste of its own, which
    /// Claude Code, Codex and Grok all attach as an image, the way a file dragged in from Finder
    /// arrives; without bracketed paste the paths go in the text.
    public static func typing(_ message: String, images: [String] = [], bracketedPaste: Bool) -> String? {
        var text = message.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !bracketedPaste, !images.isEmpty { text = (images + [text]).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
        let pastes = bracketedPaste ? images.map(paste).joined() : ""
        guard !text.isEmpty || !pastes.isEmpty else { return nil }
        let lines = text.contains("\n")
        if lines, !bracketedPaste {
            text = text.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
        // An `@path` at the end would leave the agent's file list open, and Enter would pick
        // from it instead of sending; a space after it closes the list.
        if text.split(whereSeparator: \.isWhitespace).last?.hasPrefix("@") == true { text += " " }
        return clearLine + pastes + (lines && bracketedPaste ? paste(text) : text)
    }

    private static func paste(_ text: String) -> String { "\u{1b}[200~" + text + "\u{1b}[201~" }

    /// What stops an agent's turn: Grok takes ⌃C, the others Esc.
    public static func interrupt(agent: String?) -> String {
        agent == "grok" ? "\u{3}" : escape
    }

    /// Keys that answer an approval prompt straight from an empty composer: a choice's number,
    /// or y / n / a, which the agents' prompts take as shortcuts.
    public static func isApprovalKey(_ key: String) -> Bool {
        guard key.count == 1, let char = key.first else { return false }
        return ("1"..."9").contains(char) || "yna".contains(char)
    }
}

/// The input mode an agent shows under its prompt (Claude Code's "⏵⏵ accept edits on
/// (shift+tab to cycle)"), for the composer's status line.
public enum ChatModeHint {
    public static func read(_ lines: [String]) -> String? {
        let tail = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(6)
        guard let line = tail.last(where: { $0.lowercased().contains("shift+tab") || $0.hasPrefix("⏵⏵") || $0.hasPrefix("⏸") })
        else { return nil }
        var text = line
        if let cut = text.range(of: " (") { text = String(text[..<cut.lowerBound]) }
        if let cut = text.range(of: " · ") { text = String(text[..<cut.lowerBound]) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "⏵⏸▶ ").union(.whitespaces))
        guard !text.isEmpty, text.count <= 40, !text.lowercased().contains("shift+tab") else { return nil }
        return text
    }
}

/// What an approval prompt is about, for the chat's approval card: the lines just above its
/// question (Claude Code's "Bash command / swift build / Build the project"), then any between
/// the question and its choices (Codex's "$ npm test").
public enum ChatPrompt {
    public static let contextLines = 4
    private static let borders = CharacterSet(charactersIn: "│┃║|").union(.whitespaces)
    private static let rules = CharacterSet(charactersIn: "─━═╌┄-╭╮╰╯┌┐└┘").union(.whitespaces)

    public static func context(screen lines: [String], question: String?) -> [String] {
        guard let question, !question.isEmpty else { return [] }
        let trimmed = lines.map { $0.trimmingCharacters(in: borders) }
        guard let at = trimmed.lastIndex(where: { $0.hasPrefix(question) }) else { return [] }
        var out: [String] = []
        var index = at - 1
        while index >= 0, out.count < contextLines {
            let line = trimmed[index]
            if !line.isEmpty {
                if line.unicodeScalars.allSatisfy(rules.contains) { break }
                out.insert(line, at: 0)
            }
            index -= 1
        }
        return out + between(trimmed, after: at)
    }

    /// Lines between the question and its first choice (Codex's "$ npm test").
    private static func between(_ lines: [String], after question: Int) -> [String] {
        var out: [String] = []
        for line in lines.dropFirst(question + 1) {
            let bare = line.drop { "›❯> ".contains($0) }
            if bare.first?.isNumber == true, bare.dropFirst().first == "." { break }
            if !line.isEmpty, !line.unicodeScalars.allSatisfy(rules.contains) { out.append(line) }
            if out.count == contextLines { break }
        }
        return out
    }
}
