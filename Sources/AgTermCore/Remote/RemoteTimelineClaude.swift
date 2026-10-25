import Foundation

/// One chat item from a Claude Code transcript line, as agmux's
/// `commands::claude_chat::ClaudeChatItem` (system/usage rows are dropped:
/// the timeline never renders them).
enum ClaudeChatItem: Equatable {
    case userMessage(content: String, timestamp: String, uuid: String)
    case assistantText(text: String, timestamp: String, uuid: String)
    case assistantThinking(thinking: String, timestamp: String, uuid: String)
    case toolUse(id: String, name: String, input: JSONValue, timestamp: String, uuid: String)
    case toolResult(toolUseID: String, content: String, isError: Bool, timestamp: String, uuid: String)
}

/// Claude Code transcript (`~/.claude/projects/<dir>/<session>.jsonl`) → timeline,
/// ported from agmux `claude_chat::parse_line`, `timeline::claude_items_to_entries`
/// and the queue overlay.
enum ClaudeTimeline {
    /// Queued messages are recent by nature; the overlay scans only this tail.
    static let queueTailBytes = 256 * 1024

    static func entries(transcript: String) -> [MobileTimelineEntry] {
        let base = itemsToEntries(items(transcript: transcript))
        return applyingQueueOverlay(base, transcript: transcript)
    }

    // MARK: Transcript → items

    /// `read_claude_session_history`: only complete lines (up to the last
    /// newline) count, so a line still being written is read next time.
    static func items(transcript: String) -> [ClaudeChatItem] {
        let bytes = transcript.utf8
        guard let lastNewline = bytes.lastIndex(of: 0x0A) else { return [] }
        let complete = String(decoding: bytes[...lastNewline], as: UTF8.self)
        return rustLines(complete).flatMap { line -> [ClaudeChatItem] in
            let trimmed = line.rustTrimmed
            return trimmed.isEmpty ? [] : parseLine(trimmed)
        }
    }

    static func parseLine(_ line: String) -> [ClaudeChatItem] {
        guard let v = JSONValue.parse(line), let type = v["type"]?.string else { return [] }
        let timestamp = v["timestamp"]?.string ?? ""
        let uuid = v["uuid"]?.string ?? ""
        switch type {
        case "user": return userItems(v, timestamp: timestamp, uuid: uuid)
        case "assistant": return assistantItems(v, timestamp: timestamp, uuid: uuid)
        default: return []
        }
    }

    private static func userItems(_ v: JSONValue, timestamp: String, uuid: String) -> [ClaudeChatItem] {
        // Meta rows are system/command plumbing, except slash commands.
        if v["isMeta"]?.bool == true, v.pointer("/message/content")?.string?.startsWith("/") != true { return [] }
        // Compacted sessions inject a synthetic continuation summary.
        if v["isCompactSummary"]?.bool == true { return [] }
        guard let content = v.pointer("/message/content") else { return [] }
        if let text = content.string { return [.userMessage(content: text, timestamp: timestamp, uuid: uuid)] }
        guard let blocks = content.array else { return [] }
        let multi = blocks.count > 1
        return blocks.enumerated().compactMap { index, block in
            let blockUUID = multi ? "\(uuid)-\(index)" : uuid
            switch block["type"]?.string {
            case "text":
                return block["text"]?.string.map { .userMessage(content: $0, timestamp: timestamp, uuid: blockUUID) }
            case "tool_result":
                return .toolResult(toolUseID: block["tool_use_id"]?.string ?? "",
                                   content: block["content"].map(toolResultText) ?? "",
                                   isError: block["is_error"]?.bool ?? false, timestamp: timestamp, uuid: blockUUID)
            default:
                return nil
            }
        }
    }

    private static func assistantItems(_ v: JSONValue, timestamp: String, uuid: String) -> [ClaudeChatItem] {
        guard let blocks = v.pointer("/message/content")?.array else { return [] }
        let multi = blocks.count > 1
        return blocks.enumerated().compactMap { index, block in
            let blockUUID = multi ? "\(uuid)-\(index)" : uuid
            switch block["type"]?.string {
            case "text":
                return block["text"]?.string.map { .assistantText(text: $0, timestamp: timestamp, uuid: blockUUID) }
            case "thinking":
                return .assistantThinking(thinking: block["thinking"]?.string ?? "", timestamp: timestamp, uuid: blockUUID)
            case "tool_use":
                return .toolUse(id: block["id"]?.string ?? "", name: block["name"]?.string ?? "",
                                input: block["input"] ?? .null, timestamp: timestamp, uuid: blockUUID)
            default:
                return nil
            }
        }
    }

    /// `extract_tool_result_content`.
    private static func toolResultText(_ value: JSONValue) -> String {
        if let text = value.string { return text }
        if let blocks = value.array {
            return blocks.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
        }
        return value.serdeString
    }

    // MARK: Items → entries

    /// `claude_items_to_entries`.
    static func itemsToEntries(_ items: [ClaudeChatItem]) -> [MobileTimelineEntry] {
        var out: [MobileTimelineEntry] = []
        var toolIndex: [String: Int] = [:]
        for item in items {
            switch item {
            case let .userMessage(content, timestamp, uuid):
                guard let text = ClaudeText.clean(content) else { continue }
                out.append(MobileTimelineEntry(id: uuid, kind: "user", text: text, ts: parseLogTimestamp(timestamp)))
            case let .assistantText(text, timestamp, uuid):
                guard let text = ClaudeText.clean(text) else { continue }
                out.append(MobileTimelineEntry(id: uuid, kind: "assistant", text: text, ts: parseLogTimestamp(timestamp)))
            case let .assistantThinking(thinking, timestamp, uuid):
                // Empty thinking blocks still appear in Claude JSONL.
                guard !thinking.isBlank else { continue }
                out.append(MobileTimelineEntry(id: uuid, kind: "thinking", text: thinking, ts: parseLogTimestamp(timestamp)))
            case let .toolUse(id, name, input, timestamp, uuid):
                let (subject, detail) = TimelineTools.subjectDetail(name, input)
                let entry = MobileTimelineEntry(id: uuid, kind: "tool", lead: TimelineTools.lead(name), subject: subject,
                                                detail: detail, status: "running", requestId: id, toolName: name,
                                                ts: parseLogTimestamp(timestamp))
                toolIndex[id] = out.count
                out.append(TimelineTools.filled(entry, input: input))
            case let .toolResult(toolUseID, content, isError, timestamp, uuid):
                if let index = toolIndex[toolUseID] {
                    out[index] = TimelineTools.applyingResult(out[index], content: content, isError: isError)
                } else {
                    out.append(MobileTimelineEntry(id: uuid, kind: "tool", lead: "Result", status: isError ? "error" : "ok",
                                                   body: timelineTruncate(content, TimelineTools.resultBodyLimit),
                                                   requestId: toolUseID, ts: parseLogTimestamp(timestamp)))
                }
            }
        }
        return out
    }

    // MARK: Queue overlay

    struct Delivered: Equatable { let uuid: String; let prompt: String; let ts: Int }
    struct Pending: Equatable { let content: String; let ts: Int }

    /// `apply_claude_queue_overlay`: steering typed while Claude works lives in
    /// `queue-operation` / `queued_command` records the history parser skips.
    static func applyingQueueOverlay(_ entries: [MobileTimelineEntry], transcript: String) -> [MobileTimelineEntry] {
        let bytes = Array(transcript.utf8)
        let isTail = bytes.count > queueTailBytes
        let tail = isTail ? String(decoding: bytes[(bytes.count - queueTailBytes)...], as: UTF8.self) : transcript
        let lines = Array(rustLines(tail).dropFirst(isTail ? 1 : 0))
        let (delivered, pending) = scanQueue(lines)
        if delivered.isEmpty && pending.isEmpty { return entries }
        return mergeQueue(entries, delivered: delivered, pending: pending)
    }

    /// `scan_claude_queue`.
    static func scanQueue(_ lines: [String]) -> (delivered: [Delivered], pending: [Pending]) {
        var delivered: [Delivered] = []
        var pending: [Pending] = []
        for line in lines {
            guard let v = JSONValue.parse(line) else { continue }
            let ts = parseLogTimestamp(v["timestamp"]?.string ?? "")
            switch v["type"]?.string {
            case "queue-operation":
                let op = v["operation"]?.string ?? ""
                let content = v["content"]?.string ?? ""
                switch op {
                case "enqueue":
                    pending.append(Pending(content: content, ts: ts))
                case "dequeue", "remove", "popAll":
                    // A content-less dequeue sends the front of the queue.
                    let match = pending.firstIndex { $0.content == content }
                        ?? ((op == "dequeue" && content.isEmpty && !pending.isEmpty) ? 0 : nil)
                    if let match { pending.remove(at: match) }
                default:
                    break
                }
            case "attachment":
                guard let att = v["attachment"], att["type"]?.string == "queued_command",
                      let prompt = att["prompt"]?.string else { continue }
                delivered.append(Delivered(uuid: v["uuid"]?.string ?? "queued-att", prompt: prompt, ts: ts))
            default:
                continue
            }
        }
        return (delivered, pending)
    }

    /// `merge_claude_queue`.
    static func mergeQueue(_ entries: [MobileTimelineEntry], delivered: [Delivered], pending: [Pending]) -> [MobileTimelineEntry] {
        var out = entries
        // Drop the turn-boundary duplicate user rows (same text, later ts).
        for d in delivered {
            if let pos = out.firstIndex(where: { $0.kind == "user" && $0.ts >= d.ts && ClaudeText.overlayPromptsMatch($0.text, d.prompt) }) {
                out.remove(at: pos)
            }
        }
        // Delivered steering at its chronological position.
        for d in delivered where !out.contains(where: { $0.id == d.uuid }) {
            let pos = out.firstIndex { $0.ts > d.ts } ?? out.count
            out.insert(MobileTimelineEntry(id: d.uuid, kind: "user", text: d.prompt, ts: d.ts), at: pos)
        }
        // Still-pending queue → trailing "queued" bubbles.
        for (i, p) in pending.enumerated() where !p.content.isBlank {
            out.append(MobileTimelineEntry(id: "queued-\(i)", kind: "user", text: p.content, state: "queued", ts: p.ts))
        }
        return out
    }

    // MARK: Model

    static let modelScanBytes = 64 * 1024

    /// The model agmux reports for a Claude terminal (`list_claude_sessions`):
    /// the last assistant `message.model` in the final 64 KB, else the first
    /// one in the first 64 KB. `<synthetic>` placeholders are ignored.
    static func modelLabel(transcript: String) -> String? {
        let bytes = Array(transcript.utf8)
        let tailStart = max(0, bytes.count - modelScanBytes)
        let tailLines = rustLines(String(decoding: bytes[tailStart...], as: UTF8.self)).dropFirst(tailStart > 0 ? 1 : 0)
        if let last = tailLines.compactMap(assistantModel).last { return last }
        // Head: every line that starts inside the first 64 KB.
        var headEnd = bytes.count
        if bytes.count > modelScanBytes {
            headEnd = (bytes[(modelScanBytes - 1)...].firstIndex(of: 0x0A) ?? (bytes.count - 1)) + 1
        }
        let headLines = rustLines(String(decoding: bytes[..<headEnd], as: UTF8.self))
        return headLines.lazy.compactMap(assistantModel).first
    }

    private static func assistantModel(_ line: String) -> String? {
        guard !line.isBlank, let v = JSONValue.parse(line), v["type"]?.string == "assistant",
              let model = v.pointer("/message/model")?.string, !model.isEmpty, !model.startsWith("<") else { return nil }
        return model
    }
}
