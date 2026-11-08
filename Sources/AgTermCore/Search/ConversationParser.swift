import Foundation

/// Reads transcript lines into a `ConversationRecord`. Lines that can't hold a prompt or a reply
/// (tool calls and their output, token counts…) are skipped before any JSON is parsed, so a
/// multi-gigabyte history reads quickly.
public enum ConversationParser {
    /// Ids agterm puts on a command line: letters, digits and dashes only.
    public static func isSessionID(_ id: String) -> Bool {
        id.range(of: #"^[0-9A-Za-z-]{8,64}$"#, options: .regularExpression) != nil
    }

    public static func absorb(_ line: Data, into record: inout ConversationRecord) {
        switch record.agent {
        case .claude: claude(line, into: &record)
        case .codex: codex(line, into: &record)
        case .grok: grok(line, into: &record)
        }
    }

    // MARK: Claude Code

    private static let claudeUser = Data(#""type":"user""#.utf8)
    private static let claudeAssistant = Data(#""type":"assistant""#.utf8)
    private static let claudeTitle = Data(#""ai-title""#.utf8)
    private static let textPart = Data(#""type":"text""#.utf8)
    private static let toolResult = Data(#""type":"tool_result""#.utf8)
    private static let sidechain = Data(#""isSidechain":true"#.utf8)
    private static let meta = Data(#""isMeta":true"#.utf8)

    private static func claude(_ line: Data, into record: inout ConversationRecord) {
        if line.range(of: claudeTitle) != nil, let json = object(line), json["type"] as? String == "ai-title",
           let title = json["aiTitle"] as? String, !title.isEmpty {
            record.title = title
            return
        }
        let user = line.range(of: claudeUser) != nil
        guard user || line.range(of: claudeAssistant) != nil, line.range(of: sidechain) == nil, line.range(of: meta) == nil,
              !(user && line.range(of: toolResult) != nil), user || line.range(of: textPart) != nil,
              let json = object(line), let message = json["message"] as? [String: Any] else { return }
        if record.folder == nil, let cwd = json["cwd"] as? String, !cwd.isEmpty { record.folder = cwd }
        let role = json["type"] as? String
        let texts: [String]
        if let content = message["content"] as? String {
            texts = [content]
        } else {
            texts = (message["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        }
        for text in texts {
            guard let clean = role == "user" ? ClaudeText.clean(text) : text else { continue }
            if role == "user", record.firstPrompt == nil { record.firstPrompt = promptTitle(clean) }
            record.append(clean)
        }
    }

    // MARK: Codex

    private static let codexMessage = Data(#""type":"message""#.utf8)
    private static let codexMeta = Data(#""session_meta""#.utf8)

    private static func codex(_ line: Data, into record: inout ConversationRecord) {
        if line.range(of: codexMeta) != nil, let json = object(line), json["type"] as? String == "session_meta",
           let payload = json["payload"] as? [String: Any] {
            if let id = payload["id"] as? String, isSessionID(id) { record.id = id }
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { record.folder = cwd }
            return
        }
        guard line.range(of: codexMessage) != nil, let json = object(line), json["type"] as? String == "response_item",
              let payload = json["payload"] as? [String: Any], payload["type"] as? String == "message",
              let role = payload["role"] as? String, role == "user" || role == "assistant" else { return }
        for part in payload["content"] as? [[String: Any]] ?? [] {
            guard let text = part["text"] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Codex sends your AGENTS.md and the environment as user messages of their own.
            if role == "user", trimmed.hasPrefix("<") || trimmed.hasPrefix("# AGENTS.md") { continue }
            if role == "user", record.firstPrompt == nil { record.firstPrompt = promptTitle(trimmed) }
            record.append(trimmed)
        }
    }

    /// Codex's thread names, from session_index.jsonl (`{"id", "thread_name"}` per line, newest last).
    public static func codexThreadNames(_ index: String) -> [String: String] {
        var names: [String: String] = [:]
        for line in index.split(separator: "\n") {
            guard let json = object(Data(line.utf8)), let id = json["id"] as? String,
                  let name = (json["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            names[id] = name
        }
        return names
    }

    // MARK: Grok

    private static let grokUser = Data(#"{"type":"user""#.utf8)
    private static let grokAssistant = Data(#"{"type":"assistant""#.utf8)

    private static func grok(_ line: Data, into record: inout ConversationRecord) {
        let user = line.starts(with: grokUser)
        guard user || line.starts(with: grokAssistant), let json = object(line) else { return }
        let texts: [String]
        if let content = json["content"] as? String {
            texts = [content]
        } else {
            texts = (json["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        }
        for text in texts {
            var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if user {
                // Your prompt comes wrapped in <user_query>; other tagged parts are context Grok adds.
                guard body.hasPrefix("<user_query>") else { continue }
                body = body.dropFirst("<user_query>".count).replacingOccurrences(of: "</user_query>", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if record.firstPrompt == nil { record.firstPrompt = promptTitle(body) }
            }
            record.append(body)
        }
    }

    /// Grok's summary.json: the conversation's id, folder and title.
    public static func grokSummary(_ data: Data) -> (id: String?, folder: String?, title: String?) {
        guard let json = object(data) else { return (nil, nil, nil) }
        let info = json["info"] as? [String: Any]
        let title = (json["session_summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (info?["id"] as? String, info?["cwd"] as? String, title?.isEmpty == false ? title : nil)
    }

    // MARK: Helpers

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A prompt's first line, without a leading slash command, for a title.
    static func promptTitle(_ prompt: String) -> String? {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") { text = text.drop { !$0.isWhitespace }.trimmingCharacters(in: .whitespacesAndNewlines) }
        let line = text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? nil : String(line.prefix(200))
    }
}
