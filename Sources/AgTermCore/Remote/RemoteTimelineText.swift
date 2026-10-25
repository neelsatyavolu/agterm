import Foundation

/// Claude text cleanup from agmux `remote/timeline.rs` (`clean_claude_timeline_text`
/// and friends) plus `db::queries::strip_ansi_keep_layout`, so the phone never
/// renders TUI plumbing or compact summaries as chat bubbles.
enum ClaudeText {
    private static let systemTags: NSRegularExpression = {
        let tags = ["system-reminder", "command-name", "command-message", "command-args", "local-command-caveat",
                    "local-command-stdout", "context_guidance", "context_window_protection", "task-notification",
                    "ide_opened_file", "persisted-output"]
        let pattern = "(?s)" + tags.map { "<\($0)[^>]*>.*?</\($0)>" }.joined(separator: "|")
        // The pattern is a constant; failing to compile it is a programming error.
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern)
    }()

    static func stripSystemTags(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return systemTags.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    static func isSystemBlob(_ text: String) -> Bool {
        let lower = asciiLowercased(text)
        if lower.containsBytes("this session is being continued from a previous") { return true }
        if lower.startsWith("compacting conversation") { return true }
        return ["<user_info>", "<system-reminder>", "<human_rules>", "<agent_skills>", "<command-name>",
                "<command-message>", "<local-command-caveat>"].contains { text.startsWith($0) }
    }

    /// `clean_claude_timeline_text`: nil when nothing renderable is left.
    static func clean(_ text: String) -> String? {
        let trimmed = stripANSIKeepLayout(text).rustTrimmed
        if trimmed.isEmpty || isSystemBlob(trimmed) { return nil }
        let cleaned = stripSystemTags(trimmed).rustTrimmed
        if cleaned.isEmpty || isSystemBlob(cleaned) { return nil }
        return cleaned
    }

    /// `overlay_prompts_match`: a cleaned user row is the same prompt as a queue attachment.
    static func overlayPromptsMatch(_ entryText: String?, _ prompt: String) -> Bool {
        guard let entry = entryText?.rustTrimmed, !entry.isEmpty else { return false }
        if entry == prompt.rustTrimmed { return true }
        if let cleaned = clean(prompt) { return entry == cleaned }
        return entry == stripSystemTags(prompt).rustTrimmed
    }

    /// `strip_ansi_keep_layout`: drop CSI/OSC/DCS escapes and control bytes,
    /// keeping newlines, tabs and carriage returns so markdown layout survives.
    static func stripANSIKeepLayout(_ input: String) -> String {
        let bytes = Array(input.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x1B {
                i += 1
                guard i < bytes.count else { break }
                i = skipEscape(bytes, from: i)
                continue
            }
            // C1 CSI (U+009B as C2 9B). A bare 0x9B is a continuation byte and stays.
            if b == 0xC2, i + 1 < bytes.count, bytes[i + 1] == 0x9B {
                i = skipCSI(bytes, from: i + 2)
                continue
            }
            if (b < 0x20 && b != 0x0A && b != 0x09 && b != 0x0D) || b == 0x7F {
                i += 1
                continue
            }
            out.append(b)
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Skips the sequence after an ESC; `i` points at the byte following ESC.
    private static func skipEscape(_ bytes: [UInt8], from start: Int) -> Int {
        switch bytes[start] {
        case UInt8(ascii: "["):
            return skipCSI(bytes, from: start + 1)
        case UInt8(ascii: "]"):
            var i = start + 1
            while i < bytes.count {
                if bytes[i] == 0x07 { return i + 1 }
                if bytes[i] == 0x1B, i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "\\") { return i + 2 }
                i += 1
            }
            return i
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            var i = start + 1
            while i < bytes.count {
                if bytes[i] == 0x1B, i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "\\") { return i + 2 }
                i += 1
            }
            return i
        default:
            return start + 1
        }
    }

    /// CSI parameters run until a final byte in 0x40–0x7E.
    private static func skipCSI(_ bytes: [UInt8], from start: Int) -> Int {
        var i = start
        while i < bytes.count {
            let c = bytes[i]
            i += 1
            if (0x40...0x7E).contains(c) { break }
        }
        return i
    }
}
