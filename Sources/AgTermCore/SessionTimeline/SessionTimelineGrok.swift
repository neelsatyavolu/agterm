import Foundation

/// Turns from a Grok session folder (`$GROK_HOME/sessions/<cwd>/<id>/`). `chat_history.jsonl`
/// has the prompts (user rows with a `prompt_index`, text wrapped in `<user_query>`) but no
/// times; `events.jsonl` has `turn_started` / `turn_ended` in the same order. `merge` pairs them.
public enum SessionTimelineGrok {
    /// Reads `chat_history.jsonl`.
    public struct Prompts: SessionTimelineFeed {
        public private(set) var prompts: [String] = []

        public init() {}

        public mutating func feed(_ line: String) {
            guard line.contains("\"prompt_index\""), let v = JSONValue.parse(line),
                  v["type"]?.string == "user", v["synthetic_reason"] == nil else { return }
            let raw: String
            if let text = v["content"]?.string {
                raw = text
            } else {
                raw = (v["content"]?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
                    .joined(separator: "\n")
            }
            let prompt = SessionTimelineFormat.cleanPrompt(raw)
            if !prompt.isEmpty { prompts.append(prompt) }
        }
    }

    /// Reads `events.jsonl`: when each turn started and how it ended.
    public struct Events: SessionTimelineFeed {
        public private(set) var starts: [Int?] = []
        public private(set) var outcomes: [SessionTimelineTurn.Status] = []

        public init() {}

        public mutating func feed(_ line: String) {
            // The file is mostly phase changes; parse only turn lines.
            guard line.contains("\"turn_"), let v = JSONValue.parse(line) else { return }
            switch v["type"]?.string {
            case "turn_started":
                starts.append(v["ts"]?.string.map(parseLogTimestamp))
            case "turn_ended":
                switch v["outcome"]?.string {
                case "cancelled": outcomes.append(.cancelled)
                case "error", "failed": outcomes.append(.failed)
                default: outcomes.append(.done)
                }
            default:
                break
            }
        }
    }

    /// Prompt `i` is turn `i`: a turn with no end yet is running.
    public static func merge(_ prompts: Prompts, _ events: Events, sessionID: String) -> [SessionTimelineTurn] {
        prompts.prompts.enumerated().map { i, prompt in
            let started = i < events.starts.count ? events.starts[i] : nil
            let status = i < events.outcomes.count ? events.outcomes[i] : .running
            return SessionTimelineTurn(id: "grok-\(sessionID)-\(i)", prompt: prompt, status: status, startedAt: started)
        }
    }
}
