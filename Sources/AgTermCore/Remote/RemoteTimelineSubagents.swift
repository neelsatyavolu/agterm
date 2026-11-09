import Foundation

/// Subagents and workflows across agents: which tool calls start one, the "started in the
/// background" results that mean it's still running, and the later records that say it finished.
enum Subagents {
    /// A tool call that starts a subagent (Claude `Agent`/`Task`, Codex `spawn_agent`, Grok
    /// `spawn_subagent`) or a Claude `Workflow`.
    static func isSpawn(_ name: String) -> Bool {
        isWorkflow(name) || ["task", "agent", "spawn_agent", "spawn_subagent", "dispatch_agent"].contains(base(name))
    }

    static func isWorkflow(_ name: String) -> Bool { base(name) == "workflow" }

    /// Lowercased, without an MCP prefix or a Codex namespace (`collaboration.spawn_agent`).
    static func base(_ name: String) -> String {
        let short = TimelineTools.baseName(name)
        let tail = short.split(separator: ".").last.map(String.init) ?? short
        return asciiLowercased(tail)
    }

    /// The result of a call that left its agent or workflow running in the background.
    static func isBackgroundLaunch(_ content: String) -> Bool {
        let text = content.rustTrimStart
        return ["Async agent launched", "Workflow launched in background", "Subagent started in background"]
            .contains { text.startsWith($0) }
    }

    /// A row's subject and detail: what it does and which kind of agent does it.
    static func subjectDetail(_ name: String, _ input: JSONValue) -> (subject: String?, detail: String?) {
        let cut = { (text: String) in timelineTruncate(text, 120) }
        if isWorkflow(name) {
            let script = input["script"]?.string ?? ""
            let title = metaField(script, "description") ?? metaField(script, "name") ?? input["name"]?.string
            let workflowName = metaField(script, "name") ?? input["name"]?.string
            return (title.map(cut), workflowName == title ? nil : workflowName.map(cut))
        }
        let nonEmpty = { (key: String) in input[key]?.string.flatMap { $0.isBlank ? nil : $0 } }
        let subject = nonEmpty("description") ?? nonEmpty("task_name") ?? nonEmpty("prompt").flatMap { $0.startsWith("gAAAA") ? nil : $0 }
        let detail = nonEmpty("subagent_type") ?? nonEmpty("agent_type")
        return (subject.map(cut), detail.map(cut))
    }

    /// `name: 'x'` or `description: "y"` in a workflow script's `meta` literal.
    static func metaField(_ script: String, _ key: String) -> String? {
        guard let meta = script.range(of: "meta") else { return nil }
        let rest = script[meta.upperBound...]
        guard let keyRange = rest.range(of: "\(key):") else { return nil }
        let after = rest[keyRange.upperBound...].drop { $0 == " " }
        guard let quote = after.first, "'\"`".contains(quote) else { return nil }
        let body = after.dropFirst()
        guard let end = body.firstIndex(of: quote) else { return nil }
        let value = String(body[..<end]).rustTrimmed
        return value.isEmpty ? nil : value
    }

    // MARK: Claude

    /// A finished background agent or workflow, from Claude Code's `<task-notification>`.
    struct Notification: Equatable {
        let toolUseID: String
        let failed: Bool
        let result: String?
    }

    static func claudeNotification(_ text: String) -> Notification? {
        guard let note = ClaudeText.tagBody(text, "task-notification"),
              let toolUseID = ClaudeText.tagBody(note, "tool-use-id")?.rustTrimmed, !toolUseID.isEmpty else { return nil }
        let status = asciiLowercased(ClaudeText.tagBody(note, "status")?.rustTrimmed ?? "completed")
        let result = (ClaudeText.tagBody(note, "result") ?? ClaudeText.tagBody(note, "summary")).map { ClaudeText.stripSystemTags($0).rustTrimmed }
        return Notification(toolUseID: toolUseID, failed: ["failed", "error", "killed", "stopped"].contains(status),
                            result: result.flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: Grok

    /// `subagent_id: <id>` in a `spawn_subagent` result.
    static func grokSubagentID(_ content: String) -> String? {
        for line in rustLines(content) where line.startsWith("subagent_id:") {
            let id = String(line.dropFirst("subagent_id:".count)).rustTrimmed
            if !id.isEmpty { return id }
        }
        return nil
    }

    /// A task `get_command_or_subagent_output` reports as finished.
    struct GrokTask: Equatable {
        let id: String
        let failed: Bool
        let output: String?
    }

    /// The finished tasks in a `get_command_or_subagent_output` result (`=== Task <id> ===` blocks).
    static func grokFinishedTasks(_ content: String) -> [GrokTask] {
        content.components(separatedBy: "=== Task ").dropFirst().compactMap { block in
            guard let close = block.range(of: " ===") else { return nil }
            let id = String(block[..<close.lowerBound]).rustTrimmed
            let lines = rustLines(String(block[close.upperBound...]))
            guard let status = lines.first(where: { $0.startsWith("Status:") }).map({ asciiLowercased(String($0.dropFirst(7)).rustTrimmed) }),
                  status != "running" else { return nil }
            var output: String?
            if let marker = block.range(of: "=== Output ===") {
                var text = String(block[marker.upperBound...])
                if let meta = text.range(of: "<subagent_meta>") { text = String(text[..<meta.lowerBound]) }
                output = text.rustTrimmed.isEmpty ? nil : text.rustTrimmed
            }
            return GrokTask(id: id, failed: status != "completed", output: output)
        }
    }

    /// `Background task "<id>" completed …` in a Grok task notice: the id, and whether it failed.
    static func grokTaskCompleted(_ text: String) -> (id: String, failed: Bool)? {
        guard let start = text.range(of: "Background task \"") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let tail = rest[end...].prefix(200)
        guard tail.contains("completed") else { return nil }
        return (String(rest[..<end]), tail.contains("terminated") || tail.contains("failed"))
    }
}

/// Codex subagents finish in records after their `spawn_agent` call's turn: a `SubAgentActivity`
/// event says one completed and its `FINAL_ANSWER` message carries what it found. This collects
/// them and patches the spawn rows, which stay running until then.
struct CodexSubagents {
    private var completed: [String: Int] = [:]
    private var answers: [String: String] = [:]
    /// Spawn rows among the first `scanned` entries, which don't change once settled.
    private var spawnRows: [Int] = []
    private var scanned = 0

    mutating func consume(_ record: JSONValue) {
        guard let payload = record["payload"] else { return }
        let ts = parseLogTimestamp(record["timestamp"]?.string ?? "")
        switch (record["type"]?.string, payload["type"]?.string) {
        case ("event_msg", "item_completed"):
            guard let item = payload["item"], item["type"]?.string == "SubAgentActivity",
                  item["kind"]?.string == "completed", let path = item["agent_path"]?.string else { return }
            completed[path] = ts
        case ("response_item", "agent_message"):
            guard let path = payload["author"]?.string,
                  let text = payload["content"]?.array?.compactMap({ $0["text"]?.string }).joined(),
                  text.containsBytes("Message Type: FINAL_ANSWER"), let marker = text.range(of: "Payload:") else { return }
            let answer = String(text[marker.upperBound...]).rustTrimmed
            if !answer.isEmpty { answers[path] = timelineTruncate(answer, TimelineTools.resultBodyLimit) }
        default:
            break
        }
    }

    /// Spawn rows still running until their agent completes, with its answer as their body.
    /// `settled`: how many leading entries won't change again, so they're looked through once.
    mutating func apply(to entries: [MobileTimelineEntry], settled: Int) -> [MobileTimelineEntry] {
        let stable = min(settled, entries.count)
        if stable < scanned { (spawnRows, scanned) = ([], 0) }
        spawnRows += (scanned..<stable).filter { Self.isSpawn(entries[$0]) }
        scanned = stable
        let rows = spawnRows + (stable..<entries.count).filter { Self.isSpawn(entries[$0]) }
        guard !rows.isEmpty else { return entries }
        var out = entries
        for index in rows { out[index] = patched(out[index]) }
        return out
    }

    /// The whole timeline at once (the phone's).
    func apply(to entries: [MobileTimelineEntry]) -> [MobileTimelineEntry] {
        var copy = self
        return copy.apply(to: entries, settled: 0)
    }

    private static func isSpawn(_ e: MobileTimelineEntry) -> Bool {
        e.kind == "tool" && Subagents.base(e.toolName ?? "") == "spawn_agent"
    }

    private func patched(_ entry: MobileTimelineEntry) -> MobileTimelineEntry {
        guard entry.status != "error", let path = Self.path(entry) else { return entry }
        var e = entry
        let done = completed[path]
        e.status = done == nil ? "running" : "ok"
        e.body = answers[path]
        if let done, done > 0 { e.endTs = done }
        return e
    }

    /// The agent's path (`/root/ts_review`) from the spawn call's output.
    private static func path(_ e: MobileTimelineEntry) -> String? {
        guard let body = e.body, let output = JSONValue.parse(body) else { return nil }
        return output["task_name"]?.string ?? output["agent_path"]?.string
    }
}
