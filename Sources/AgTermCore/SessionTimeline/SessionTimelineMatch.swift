import Foundation

/// Finding a turn in the terminal's text, ported from agmux `ptyTimelineJump.ts`. Works on the
/// buffer's rows as plain strings, oldest first.
public enum SessionTimelineMatch {
    /// Characters an agent draws in front of an echoed prompt (Claude's `>`/`❯`, Codex's `›`, boxes).
    private static let promptMarkers: Set<Character> = ["❯", "›", ">", "│", "┃"]

    /// The rows where `prompt` was echoed, counting `occurrenceFromEnd` repeats back from the
    /// newest (so the same prompt sent twice finds the right one even after old rows scroll off).
    /// `codex`: only rows starting with Codex's `›` marker count, so an answer quoting your words
    /// isn't mistaken for them. Nil when the prompt isn't on screen or in the scrollback.
    public static func promptRows(in lines: [String], prompt: String, occurrenceFromEnd: Int = 0, codex: Bool = false) -> Range<Int>? {
        let target = flat(SessionTimelineFormat.cleanPrompt(prompt))
        guard !target.isEmpty else { return nil }
        var matches: [Range<Int>] = []
        var marked: [Range<Int>] = []
        for y in lines.indices {
            guard let end = echoEnd(lines, at: y, target: target, codex: codex) else { continue }
            matches.append(y..<end)
            if echoedText(lines[y], requireMarker: true) != nil { marked.append(y..<end) }
        }
        // Rows with a prompt marker are your messages; others may be an answer quoting them.
        if !marked.isEmpty { matches = marked }
        if matches.isEmpty, !codex {
            // A long or pasted prompt the agent shortened on screen: match its opening words.
            let needle = String(target.prefix(32))
            if needle.count >= 8 {
                matches = lines.indices
                    .filter { echoedText(lines[$0], requireMarker: true).map { flat($0).hasPrefix(needle) } == true }
                    .map { $0..<($0 + 1) }
            }
        }
        let index = matches.count - 1 - max(0, occurrenceFromEnd)
        return matches.indices.contains(index) ? matches[index] : nil
    }

    /// The first row of `promptRows`.
    public static func promptRow(in lines: [String], prompt: String, occurrenceFromEnd: Int = 0, codex: Bool = false) -> Int? {
        promptRows(in: lines, prompt: prompt, occurrenceFromEnd: occurrenceFromEnd, codex: codex)?.lowerBound
    }

    /// Where the echo of `target` starting at row `y` ends (exclusive); nil if none starts there.
    private static func echoEnd(_ lines: [String], at y: Int, target: String, codex: Bool) -> Int? {
        guard var text = echoedText(lines[y], requireMarker: codex), !flat(text).isEmpty, target.hasPrefix(flat(text)) else { return nil }
        // Wrapped or multi-line prompts continue on the rows below.
        var end = y + 1
        while flat(text).count < target.count, end < lines.count {
            if codex, echoedText(lines[end], requireMarker: true) != nil { break }
            text += " " + lines[end].trimmingCharacters(in: .whitespaces)
            end += 1
        }
        return flat(text) == target || flat(text).hasPrefix(target) ? end : nil
    }

    /// The row's text after an agent's prompt marker; with `requireMarker`, nil when it has none.
    static func echoedText(_ line: String, requireMarker: Bool) -> String? {
        let trimmed = line.drop { $0 == " " || $0 == "\u{A0}" }
        if let first = trimmed.first, promptMarkers.contains(first) {
            return trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        return requireMarker ? nil : trimmed.trimmingCharacters(in: .whitespaces)
    }

    /// Whitespace collapsed, so wrapping and indentation don't matter.
    static func flat(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Grok

    /// Which part of Grok's screen has the keyboard, read off the key hints in its footer.
    public enum GrokFocus: Equatable { case scrollback, prompt, unknown }

    /// agmux `grokFocusState`. `unknown` means no footer we recognize: send Grok nothing then.
    public static func grokFocus(_ lines: [String]) -> GrokFocus {
        let hay = normalized(lines.joined(separator: " "))
        if ["j/k:nav", "shift+l/h:turn", "g/shift+g:top/btm"].contains(where: { hay.contains(normalized($0)) }) { return .scrollback }
        if ["shift+tab:mode", "enter:send", "opt+enter:newline"].contains(where: { hay.contains(normalized($0)) }) { return .prompt }
        return .unknown
    }

    /// agmux `ptyFrameFingerprint`: the screen without digits, so spinners and timers ticking
    /// don't read as the view moving.
    public static func fingerprint(_ lines: [String]) -> String {
        normalized(lines.joined(separator: "\n")).filter { !$0.isNumber }
    }

    /// agmux `normalizeTimelineHaystack`: lowercased, box drawing and punctuation dropped.
    static func normalized(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.map { scalar -> Character in
            if (0x2500...0x257F).contains(scalar.value) { return " " }
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII { return Character(scalar) }
            return "/._-".unicodeScalars.contains(scalar) ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
