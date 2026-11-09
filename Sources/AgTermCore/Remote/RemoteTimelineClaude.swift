import Foundation

/// One chat item from a Claude Code transcript line, as agmux's
/// `commands::claude_chat::ClaudeChatItem` (system/usage rows are dropped:
/// the timeline never renders them).
enum ClaudeChatItem: Equatable {
    case userMessage(content: String, timestamp: String, uuid: String)
    case assistantText(text: String, timestamp: String, uuid: String)
    case assistantThinking(thinking: String, timestamp: String, uuid: String)
    case toolUse(id: String, name: String, input: JSONValue, timestamp: String, uuid: String)
    /// `patch`: the real unified diff Claude Code recorded for an edit (`toolUseResult.structuredPatch`).
    case toolResult(toolUseID: String, content: String, isError: Bool, timestamp: String, uuid: String, patch: String? = nil)
}

/// Claude Code transcript (`~/.claude/projects/<dir>/<session>.jsonl`) → timeline,
/// ported from agmux `claude_chat::parse_line`, `timeline::claude_items_to_entries`
/// and the queue overlay.
enum ClaudeTimeline {
    /// Queued messages are recent by nature; the overlay scans only this tail.
    static let queueTailBytes = 256 * 1024

    static func entries(transcript: String, chatMarkers: Bool = false) -> [MobileTimelineEntry] {
        let base = itemsToEntries(items(transcript: transcript), chatMarkers: chatMarkers)
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
        JSONValue.parse(line).map(parseRecord) ?? []
    }

    /// Only `user` and `assistant` records make rows. A cheap look at the raw line, so the
    /// big records Claude Code also writes (attachments, request blobs, progress) aren't parsed.
    static func mayHaveRows(_ line: String) -> Bool {
        line.containsBytes("\"type\":\"user\"") || line.containsBytes("\"type\":\"assistant\"")
            || line.containsBytes("\"type\": \"user\"") || line.containsBytes("\"type\": \"assistant\"")
    }

    static func parseRecord(_ v: JSONValue) -> [ClaudeChatItem] {
        guard let type = v["type"]?.string else { return [] }
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
        // A message with pictures is one row: its text plus an image marker.
        if !blocks.contains(where: { $0["type"]?.string == "tool_result" }), let text = textWithImages(blocks) {
            return [.userMessage(content: text, timestamp: timestamp, uuid: uuid)]
        }
        let patch = v["toolUseResult"].flatMap(structuredPatch)
        let multi = blocks.count > 1
        return blocks.enumerated().compactMap { index, block in
            let blockUUID = multi ? "\(uuid)-\(index)" : uuid
            switch block["type"]?.string {
            case "text":
                return block["text"]?.string.map { .userMessage(content: $0, timestamp: timestamp, uuid: blockUUID) }
            case "tool_result":
                return .toolResult(toolUseID: block["tool_use_id"]?.string ?? "",
                                   content: block["content"].map(toolResultText) ?? "",
                                   isError: block["is_error"]?.bool ?? false, timestamp: timestamp, uuid: blockUUID,
                                   patch: blocks.count == 1 ? patch : nil)
            default:
                return nil
            }
        }
    }

    /// Text blocks joined, with `[image]` for each picture the text doesn't already name
    /// (`[Image #1]`); nil when the blocks hold no image.
    static func textWithImages(_ blocks: [JSONValue]) -> String? {
        let images = blocks.filter { $0["type"]?.string == "image" }.count
        guard images > 0 else { return nil }
        let text = blocks.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
        if text.containsBytes("[Image") { return text }
        let marker = Array(repeating: "[image]", count: images).joined(separator: " ")
        return text.isBlank ? marker : text + "\n" + marker
    }

    /// `toolUseResult.structuredPatch` hunks as one unified diff.
    static func structuredPatch(_ result: JSONValue) -> String? {
        guard let hunks = result["structuredPatch"]?.array, !hunks.isEmpty else { return nil }
        let diff = hunks.map { hunk -> String in
            let header = "@@ -\(hunk["oldStart"]?.int ?? 0),\(hunk["oldLines"]?.int ?? 0) "
                + "+\(hunk["newStart"]?.int ?? 0),\(hunk["newLines"]?.int ?? 0) @@"
            let lines = hunk["lines"]?.array?.compactMap(\.string) ?? []
            return ([header] + lines).joined(separator: "\n")
        }.joined(separator: "\n")
        return TimelineTools.looksLikeDiff(diff) ? diff : nil
    }

    private static func assistantItems(_ v: JSONValue, timestamp: String, uuid: String) -> [ClaudeChatItem] {
        guard let blocks = v.pointer("/message/content")?.array else { return [] }
        let multi = blocks.count > 1
        return blocks.enumerated().compactMap { index, block in
            let blockUUID = multi ? "\(uuid)-\(index)" : uuid
            switch block["type"]?.string {
            case "text":
                return block["text"]?.string.map { .assistantText(text: $0, timestamp: timestamp, uuid: blockUUID) }
            case "thinking", "redacted_thinking":
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
        let text: String
        if let s = value.string {
            text = s
        } else if let blocks = value.array {
            text = blocks.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
        } else {
            return value.serdeString
        }
        // Claude Code wraps a failed call's message in `<tool_use_error>`.
        return ClaudeText.tagBody(text, "tool_use_error") ?? text
    }

    // MARK: Items → entries

    /// `claude_items_to_entries`.
    static func itemsToEntries(_ items: [ClaudeChatItem], chatMarkers: Bool = false) -> [MobileTimelineEntry] {
        var fold = Fold(chatMarkers: chatMarkers)
        items.forEach { fold.add($0) }
        return fold.entries
    }

    /// `claude_items_to_entries` an item at a time, so a growing transcript is folded once.
    struct Fold {
        private(set) var entries: [MobileTimelineEntry] = []
        private var toolIndex: [String: Int] = [:]
        /// Chat view extras the phone doesn't get: a line for thinking Claude kept to itself
        /// (signed but empty, or redacted), and `!` shell commands as command rows.
        var chatMarkers = false
        /// The last `!` command row, for the output record that follows it.
        private var bangIndex: Int?

        init(chatMarkers: Bool = false) {
            self.chatMarkers = chatMarkers
        }

        mutating func add(_ item: ClaudeChatItem) {
            switch item {
            case let .userMessage(content, timestamp, uuid):
                if chatMarkers, addBangShell(content, ts: parseLogTimestamp(timestamp), uuid: uuid) { return }
                if let note = Subagents.claudeNotification(content) { finish(note, ts: parseLogTimestamp(timestamp)) }
                guard let text = ClaudeText.clean(content) else { return }
                entries.append(MobileTimelineEntry(id: uuid, kind: "user", text: text, ts: parseLogTimestamp(timestamp)))
            case let .assistantText(text, timestamp, uuid):
                guard let text = ClaudeText.clean(text) else { return }
                entries.append(MobileTimelineEntry(id: uuid, kind: "assistant", text: text, ts: parseLogTimestamp(timestamp)))
            case let .assistantThinking(thinking, timestamp, uuid):
                // Empty thinking blocks still appear in Claude JSONL.
                guard chatMarkers || !thinking.isBlank else { return }
                entries.append(MobileTimelineEntry(id: uuid, kind: "thinking", text: thinking, ts: parseLogTimestamp(timestamp)))
            case let .toolUse(id, name, input, timestamp, uuid):
                let (subject, detail) = TimelineTools.subjectDetail(name, input)
                let entry = MobileTimelineEntry(id: uuid, kind: "tool", lead: TimelineTools.lead(name), subject: subject,
                                                detail: detail, status: "running", requestId: id, toolName: name,
                                                ts: parseLogTimestamp(timestamp))
                toolIndex[id] = entries.count
                entries.append(TimelineTools.filled(entry, input: input))
            case let .toolResult(toolUseID, content, isError, timestamp, uuid, patch):
                if let index = toolIndex[toolUseID] {
                    let isAgent = TimelineTools.isAgentTool(entries[index].toolName ?? "")
                    var entry = TimelineTools.applyingResult(entries[index], content: isAgent ? ClaudeText.stripSystemTags(content) : content,
                                                             isError: isError)
                    if !isError, let patch, TimelineTools.fileMutation(entry.toolName ?? "") != nil {
                        let counts = TimelineTools.countDiffPlusMinus(patch)
                        entry.body = timelineTruncate(patch, TimelineTools.diffBodyLimit)
                        entry.additions = counts.additions > 0 ? counts.additions : nil
                        entry.deletions = counts.deletions > 0 ? counts.deletions : nil
                    }
                    if chatMarkers { entry.endTs = parseLogTimestamp(timestamp) }
                    // A background agent or workflow runs on until its task notification.
                    if !isError, Subagents.isSpawn(entry.toolName ?? ""), Subagents.isBackgroundLaunch(content) {
                        entry.status = "running"
                        entry.body = nil
                        entry.endTs = nil
                    }
                    entries[index] = entry
                } else {
                    entries.append(MobileTimelineEntry(id: uuid, kind: "tool", lead: "Result", status: isError ? "error" : "ok",
                                                       body: timelineTruncate(content, TimelineTools.resultBodyLimit),
                                                       requestId: toolUseID, ts: parseLogTimestamp(timestamp)))
                }
            }
        }

        /// A background agent or workflow finished: its row takes the notification's status and result.
        private mutating func finish(_ note: Subagents.Notification, ts: Int) {
            guard let index = toolIndex[note.toolUseID], index < entries.count else { return }
            entries[index].status = note.failed ? "error" : "ok"
            entries[index].body = note.result.map { timelineTruncate($0, TimelineTools.resultBodyLimit) }
            if chatMarkers { entries[index].endTs = ts }
        }

        /// `!cmd` typed in Claude Code: `<bash-input>` opens a command row, the
        /// `<bash-stdout>`/`<bash-stderr>` record after it fills its output. True when handled.
        private mutating func addBangShell(_ content: String, ts: Int, uuid: String) -> Bool {
            let text = content.rustTrimmed
            if let cmd = ClaudeText.tagBody(text, "bash-input") {
                bangIndex = entries.count
                entries.append(MobileTimelineEntry(id: uuid, kind: "tool", lead: "Ran", subject: timelineTruncate(cmd.rustTrimmed, 120),
                                                   status: "running", toolName: "Bash", ts: ts))
                return true
            }
            guard text.startsWith("<bash-stdout>") || text.startsWith("<bash-stderr>") else { return false }
            let out = (ClaudeText.tagBody(text, "bash-stdout") ?? "").rustTrimEnd
            let err = (ClaudeText.tagBody(text, "bash-stderr") ?? "").rustTrimEnd
            let body = [out, err].filter { !$0.isBlank }.joined(separator: "\n")
            if let index = bangIndex, index < entries.count {
                entries[index].status = out.isBlank && !err.isBlank ? "error" : "ok"
                entries[index].body = body.isEmpty ? nil : timelineTruncate(body, TimelineTools.resultBodyLimit)
                entries[index].endTs = ts
                bangIndex = nil
            }
            return true
        }
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
        // Claude Code's queue isn't FIFO, so a content-less dequeue can't say which
        // item left. Count those and settle them after every named remove has matched.
        var unnamedDequeues = 0
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
                    if op == "dequeue" && content.isEmpty {
                        unnamedDequeues += 1
                    } else if let match = pending.firstIndex(where: { $0.content == content }) {
                        pending.remove(at: match)
                    } else if unnamedDequeues > 0 {
                        // An earlier unnamed dequeue already sent this one.
                        unnamedDequeues -= 1
                    }
                default:
                    break
                }
            case "attachment":
                guard let att = v["attachment"], att["type"]?.string == "queued_command",
                      let prompt = att["prompt"]?.string ?? att["prompt"]?.array.map(queuedPromptText) else { continue }
                delivered.append(Delivered(uuid: v["uuid"]?.string ?? "queued-att", prompt: prompt, ts: ts))
            default:
                continue
            }
        }
        // Whatever the unnamed dequeues sent, the oldest items are the best guess.
        pending.removeFirst(min(unnamedDequeues, pending.count))
        return (delivered, pending)
    }

    /// A queued prompt sent as blocks (text plus pictures).
    private static func queuedPromptText(_ blocks: [JSONValue]) -> String {
        textWithImages(blocks) ?? blocks.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
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
        // Task and monitor notifications arrive this way too; their XML is plumbing.
        for d in delivered where !out.contains(where: { $0.id == d.uuid }) {
            guard let text = ClaudeText.clean(d.prompt) else { continue }
            let pos = out.firstIndex { $0.ts > d.ts } ?? out.count
            out.insert(MobileTimelineEntry(id: d.uuid, kind: "user", text: text, ts: d.ts), at: pos)
        }
        // Still-pending queue → trailing "queued" bubbles.
        for (i, p) in pending.enumerated() {
            guard let text = ClaudeText.clean(p.content) else { continue }
            out.append(MobileTimelineEntry(id: "queued-\(i)", kind: "user", text: text, state: "queued", ts: p.ts))
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

    static func assistantModel(_ line: String) -> String? {
        guard !line.isBlank, let v = JSONValue.parse(line) else { return nil }
        return assistantModel(v)
    }

    static func assistantModel(_ v: JSONValue) -> String? {
        guard v["type"]?.string == "assistant",
              let model = v.pointer("/message/model")?.string, !model.isEmpty, !model.startsWith("<") else { return nil }
        return model
    }
}
