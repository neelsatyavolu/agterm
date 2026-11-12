import Foundation

/// A Codex session's name. Codex puts only the folder in the terminal title, so the tab reads the
/// thread name from session_index.jsonl, else the first prompt from the rollout.
public enum CodexSessionTitle {
    /// The terminal title says nothing about the conversation.
    public static func isGeneric(_ topic: String, cwd: String) -> Bool {
        topic.isEmpty || topic == "Codex" || topic == (cwd as NSString).lastPathComponent
    }

    /// The thread's name when Codex has given it one, else the first prompt.
    public static func title(threadName: String?, scanner: Scanner) -> String? {
        threadName ?? scanner.title
    }

    /// The rollout's first prompt, a line at a time, so a growing rollout is read once.
    public struct Scanner {
        public private(set) var title: String?
        private static let message = #""type":"message""#

        public init() {}

        public mutating func feed<Line: StringProtocol>(_ line: Line) {
            guard title == nil, line.contains(Self.message), line.contains(#""role":"user""#),
                  let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["type"] as? String == "response_item", let payload = json["payload"] as? [String: Any] else { return }
            for part in payload["content"] as? [[String: Any]] ?? [] {
                guard let text = (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      // Codex sends your AGENTS.md and the environment as user messages of their own.
                      !text.hasPrefix("<"), !text.hasPrefix("# AGENTS.md"),
                      let prompt = ConversationParser.promptTitle(text) else { continue }
                title = prompt
                return
            }
        }
    }
}
