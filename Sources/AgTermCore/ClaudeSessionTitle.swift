import Foundation

/// A Claude Code session's name, read from its transcript. Claude Code only puts a topic in the
/// terminal title once it has generated an `ai-title`, and a session opened with a slash command
/// (a skill, `/model`…) may never get one, leaving the title at "Claude Code".
public enum ClaudeSessionTitle {
    /// The terminal title says nothing about the conversation.
    public static func isGeneric(_ topic: String) -> Bool {
        topic.isEmpty || topic == "Claude Code"
    }

    /// The latest `ai-title`, else the first prompt without its leading slash command.
    public static func parse(lines: String) -> String? {
        var aiTitle: String?, firstPrompt: String?
        for line in lines.split(separator: "\n") {
            guard line.contains("\"ai-title\"") || (firstPrompt == nil && line.contains("\"last-prompt\"")),
                  let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if record["type"] as? String == "ai-title", let title = record["aiTitle"] as? String, !title.isEmpty {
                aiTitle = title
            } else if record["type"] as? String == "last-prompt", let prompt = record["lastPrompt"] as? String {
                firstPrompt = prompt
            }
        }
        return aiTitle ?? firstPrompt.flatMap(promptTitle)
    }

    private static func promptTitle(_ prompt: String) -> String? {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") {
            text = text.drop { !$0.isWhitespace }.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let line = text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? nil : line
    }
}
