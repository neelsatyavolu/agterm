import Foundation

/// Grok session history (`~/.grok/sessions/<cwd, percent-encoded>/<id>/chat_history.jsonl`) →
/// timeline, a line at a time. Lines carry `type` user / assistant / reasoning / tool_result /
/// system / backend_tool_call and no timestamps; tool calls ride on assistant lines and their
/// results follow as `tool_result` lines.
struct GrokTimeline {
    private(set) var entries: [MobileTimelineEntry] = []
    /// The latest assistant `model_id` (`grok-4.7-build-fast`).
    private(set) var model: String?
    private var toolIndex: [String: Int] = [:]
    /// Background subagents by id: the row of the `spawn_subagent` call that started each.
    private var subagentIndex: [String: Int] = [:]
    private var line = 0

    static func entries(chatHistory: String) -> [MobileTimelineEntry] {
        var timeline = GrokTimeline()
        timeline.feed(completeLinesOf: chatHistory)
        return timeline.entries
    }

    static func modelLabel(chatHistory: String) -> String? {
        var timeline = GrokTimeline()
        timeline.feed(completeLinesOf: chatHistory)
        return timeline.model
    }

    /// Only lines up to the last newline: a line still being written is read next time.
    private mutating func feed(completeLinesOf text: String) {
        let bytes = text.utf8
        guard let lastNewline = bytes.lastIndex(of: 0x0A) else { return }
        rustLines(String(decoding: bytes[...lastNewline], as: UTF8.self)).forEach { feed($0) }
    }

    /// One line, without its newline. Every line counts toward ids, so they stay stable as the file grows.
    mutating func feed(_ text: String) {
        defer { line += 1 }
        let trimmed = text.rustTrimmed
        guard !trimmed.isEmpty, let v = JSONValue.parse(trimmed) else { return }
        let id = "grok-\(line)"
        switch v["type"]?.string {
        case "user": addUser(v, id: id)
        case "reasoning":
            let summary = (v["summary"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n\n")
            if !summary.isBlank { entries.append(MobileTimelineEntry(id: id, kind: "thinking", text: summary.rustTrimmed, ts: 0)) }
        case "assistant": addAssistant(v, id: id)
        case "tool_result": addResult(v, id: id)
        case "backend_tool_call": addBackendTool(v, id: id)
        default: break
        }
    }

    // MARK: Lines

    private mutating func addUser(_ v: JSONValue, id: String) {
        let blocks = v["content"]?.array ?? (v["content"]?.string).map { [.object(["type": .string("text"), "text": .string($0)])] } ?? []
        let raw = blocks.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
        // Reminders, task notices and compaction summaries are plumbing; an interjection is the user typing mid-turn.
        if let reason = v["synthetic_reason"]?.string, reason != "interjection" {
            if reason == "task_completed", let done = Subagents.grokTaskCompleted(raw) { finishSubagent(done.id, failed: done.failed, output: nil) }
            return
        }
        if raw.startsWith("[Image extracted from tool result") { return }
        let images = blocks.filter { $0["type"]?.string == "image" }.count
        guard var text = raw.containsBytes("<user_query>") ? Self.userQuery(raw) : ClaudeText.clean(raw) else { return }
        if images > 0 { text += "\n" + (1...images).map { "[Image #\($0)]" }.joined(separator: " ") }
        if v["prior_turn_interrupt"] != nil { entries.append(MobileTimelineEntry(id: id + "-int", kind: "interrupted", ts: 0)) }
        entries.append(MobileTimelineEntry(id: id, kind: "user", text: text, ts: 0))
    }

    /// What the user typed: the last `<user_query>` block, when the message has one.
    static func userQuery(_ text: String) -> String? {
        guard let open = text.range(of: "<user_query>", options: [.literal, .backwards]) else { return nil }
        let rest = text[open.upperBound...]
        let close = rest.range(of: "</user_query>", options: .literal)?.lowerBound ?? rest.endIndex
        let query = String(rest[..<close]).rustTrimmed
        // `/goal` sends the goal inside harness instructions: show just the goal.
        if let goal = goalText(query) { return "Goal: " + goal }
        let cleaned = query.startsWith("<system-reminder>") ? ClaudeText.stripSystemTags(query).rustTrimmed : query
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The goal in Grok's `/goal` reminder ("A goal has been set: <goal>\n\n<instructions>").
    static func goalText(_ query: String) -> String? {
        guard query.startsWith("<system-reminder>"), let marker = query.range(of: "A goal has been set:") else { return nil }
        let rest = query[marker.upperBound...]
        let end = rest.range(of: "\n\n")?.lowerBound ?? rest.range(of: "</system-reminder>")?.lowerBound ?? rest.endIndex
        let goal = String(rest[..<end]).rustTrimmed
        return goal.isEmpty ? nil : goal
    }

    private mutating func addAssistant(_ v: JSONValue, id: String) {
        if let model = v["model_id"]?.string, !model.isEmpty { self.model = model }
        if let text = v["content"]?.string, !text.isBlank {
            entries.append(MobileTimelineEntry(id: id, kind: "assistant", text: text.rustTrimmed, ts: 0))
        }
        for (k, call) in (v["tool_calls"]?.array ?? []).enumerated() {
            let callID = call["id"]?.string ?? ""
            let args = call["arguments"]?.string.flatMap { JSONValue.parse($0) } ?? call["arguments"] ?? .object([:])
            let (name, input) = TimelineTools.unwrapNested(call["name"]?.string ?? "tool", args)
            let normalized = Self.normalized(input)
            let (subject, detail) = TimelineTools.subjectDetail(name, normalized)
            let entry = MobileTimelineEntry(id: "\(id)-t\(k)", kind: "tool", lead: TimelineTools.lead(name), subject: subject,
                                            detail: detail, status: "running", requestId: callID, toolName: name, ts: 0)
            if !callID.isEmpty { toolIndex[callID] = entries.count }
            entries.append(TimelineTools.filled(entry, input: normalized))
        }
    }

    /// Grok names some arguments differently from Claude: `target_directory`, `url`.
    private static func normalized(_ input: JSONValue) -> JSONValue {
        guard var fields = input.object else { return input }
        if fields["path"] == nil, let dir = fields["target_directory"] { fields["path"] = dir }
        if fields["query"] == nil, let url = fields["url"] { fields["query"] = url }
        return .object(fields)
    }

    private mutating func addResult(_ v: JSONValue, id: String) {
        let callID = v["tool_call_id"]?.string ?? ""
        let content: String
        if let text = v["content"]?.string {
            content = text
        } else if let blocks = v["content"]?.array {
            content = blocks.compactMap { $0["text"]?.string }.joined(separator: "\n")
        } else {
            content = v["content"]?.serdeString ?? ""
        }
        if let index = toolIndex[callID] {
            let (body, isError) = Self.result(content, command: entries[index].lead == "Ran")
            entries[index] = TimelineTools.applyingResult(entries[index], content: body, isError: isError)
            trackSubagents(at: index, content: content, isError: isError)
        } else {
            let (body, isError) = Self.result(content, command: false)
            entries.append(MobileTimelineEntry(id: id, kind: "tool", lead: "Result", status: isError ? "error" : "ok",
                                               body: timelineTruncate(body, TimelineTools.resultBodyLimit), requestId: callID, ts: 0))
        }
    }

    /// A subagent started in the background keeps its row running; a later output check finishes it.
    private mutating func trackSubagents(at index: Int, content: String, isError: Bool) {
        guard !isError else { return }
        let name = entries[index].toolName ?? ""
        if Subagents.isSpawn(name), Subagents.isBackgroundLaunch(content) {
            entries[index].status = "running"
            entries[index].body = nil
            if let id = Subagents.grokSubagentID(content) { subagentIndex[id] = index }
        } else if Subagents.base(name) == "get_command_or_subagent_output" {
            Subagents.grokFinishedTasks(content).forEach { finishSubagent($0.id, failed: $0.failed, output: $0.output) }
        }
    }

    private mutating func finishSubagent(_ id: String, failed: Bool, output: String?) {
        guard let index = subagentIndex[id], index < entries.count else { return }
        entries[index].status = failed ? "error" : "ok"
        if let output { entries[index].body = timelineTruncate(output, TimelineTools.resultBodyLimit) }
    }

    /// Grok marks failures only in the text: a non-zero `exit: N` first line on commands, or an error prefix.
    static func result(_ content: String, command: Bool) -> (body: String, isError: Bool) {
        if command, content.startsWith("exit: ") {
            let firstEnd = content.firstIndex(of: "\n") ?? content.endIndex
            let first = content[content.index(content.startIndex, offsetBy: 6)..<firstEnd]
            let code = Int(first.prefix { $0.isNumber }) ?? 0
            let rest = firstEnd == content.endIndex ? "" : String(content[content.index(after: firstEnd)...])
            return (rest.rustTrimEnd, code != 0)
        }
        let errorPrefixes = ["Error:", "Error calling tool:", "Failed to call ", "Tool `", "Hook denied:",
                             "The string to replace was not found"]
        let failed = errorPrefixes.contains { content.startsWith($0) }
            && (!content.startsWith("Tool `") || content.containsBytes("` failed"))
        return (content, failed)
    }

    private mutating func addBackendTool(_ v: JSONValue, id: String) {
        guard let kind = v["kind"], let type = kind["tool_type"]?.string else { return }
        let query = kind.pointer("/action/query")?.string ?? kind.pointer("/action/url")?.string
        entries.append(MobileTimelineEntry(id: id, kind: "tool", lead: TimelineTools.lead(type),
                                           subject: query.map { timelineTruncate($0, 120) }, status: "ok", toolName: type, ts: 0))
    }
}
