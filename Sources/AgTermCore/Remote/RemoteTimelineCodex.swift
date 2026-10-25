import Foundation

/// Codex rollout (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) → timeline,
/// ported from agmux `commands::codex::parse_session_history_content` and
/// `remote::timeline::codex_items_to_entries`.
enum CodexTimeline {
    static func entries(rollout: String) -> [MobileTimelineEntry] {
        itemsToEntries(CodexHistoryParser.items(rollout: rollout))
    }

    /// The model agmux reports for a Codex session: the last non-empty
    /// `turn_context.model` (`scan_live_snapshot_uncached`).
    static func modelLabel(rollout: String) -> String? {
        var model: String?
        for line in rustLines(rollout) {
            let trimmed = line.rustTrimmed
            guard !trimmed.isEmpty, let v = JSONValue.parse(trimmed), v["type"]?.string == "turn_context",
                  let current = v.pointer("/payload/model")?.string, !current.isEmpty else { continue }
            model = current
        }
        return model
    }

    /// `is_codex_system_user_message`: AGENTS.md / environment injections.
    static func isSystemUserMessage(_ content: String) -> Bool {
        content.rustTrimStart.startsWith("# AGENTS.md")
            || content.containsBytes("<environment_context>")
            || content.containsBytes("<turn_aborted>")
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func itemsToEntries(_ items: [CodexHistoryItem]) -> [MobileTimelineEntry] {
        var out: [MobileTimelineEntry] = []
        var toolIndex: [String: Int] = [:]
        var seenFirstUser = false
        for (i, item) in items.enumerated() {
            let ts = parseLogTimestamp(item.timestamp)
            let id = "codex-\(i)"
            switch item.role {
            case "user":
                let text = item.content.rustTrimmed
                if text.isEmpty { continue }
                if !seenFirstUser {
                    seenFirstUser = true
                    if text.startsWith("# AGENTS.md") { continue }
                }
                if isSystemUserMessage(text) { continue }
                out.append(MobileTimelineEntry(id: id, kind: "user", text: text, ts: ts))
            case "assistant", "thinking":
                let text = item.content.rustTrimmed
                if text.isEmpty { continue }
                out.append(MobileTimelineEntry(id: id, kind: item.role, text: text, ts: ts))
            case "command":
                // "$ <cmd>\n<output>\n[exit: N]" splits back into subject and body.
                let (cmd, output, exitCode) = splitCommand(item.content)
                let errored = item.toolError == true || (exitCode ?? 0) != 0
                out.append(MobileTimelineEntry(id: id, kind: "tool", lead: "Ran", subject: timelineTruncate(cmd, 120),
                                               status: errored ? "error" : "ok",
                                               body: output.isBlank ? nil : timelineTruncate(output, TimelineTools.resultBodyLimit),
                                               toolName: "Shell", ts: ts))
            case "file":
                let path = item.filePath ?? item.content
                let body = item.content.isBlank ? nil : timelineTruncate(item.content, TimelineTools.resultBodyLimit)
                let counted = body.map(TimelineTools.countDiffPlusMinus) ?? (additions: 0, deletions: 0)
                out.append(MobileTimelineEntry(id: id, kind: "tool", lead: "Edited", subject: timelineTruncate(path, 120),
                                               status: "ok",
                                               additions: item.additions ?? (counted.additions > 0 ? counted.additions : nil),
                                               deletions: item.deletions ?? (counted.deletions > 0 ? counted.deletions : nil),
                                               body: body, toolName: "Edit", ts: ts))
            default:
                guard let name = item.toolName else {
                    if !item.content.isBlank {
                        out.append(MobileTimelineEntry(id: id, kind: "assistant", text: item.content, ts: ts))
                    }
                    continue
                }
                let input = item.toolInput ?? .object([:])
                let callID = input["callId"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                let isError = item.toolError == true
                if name == "ToolResult", let callID, let index = toolIndex[callID] {
                    out[index] = TimelineTools.applyingResult(out[index], content: item.content, isError: isError)
                    continue
                }
                let (subject, detail) = TimelineTools.subjectDetail(name, input)
                let status = isError ? "error"
                    : (callID != nil && name != "ToolResult" && item.content.isEmpty) ? "running" : "ok"
                var entry = MobileTimelineEntry(id: id, kind: "tool", lead: TimelineTools.lead(name), subject: subject,
                                                detail: detail, status: status,
                                                body: item.content.isBlank ? nil : timelineTruncate(item.content, TimelineTools.resultBodyLimit),
                                                requestId: callID, toolName: name, ts: ts)
                entry = TimelineTools.filled(entry, input: input)
                if isError { entry = TimelineTools.applyingResult(entry, content: item.content, isError: true) }
                if name != "ToolResult", let callID { toolIndex[callID] = out.count }
                out.append(entry)
            }
        }
        return out
    }

    /// `split_codex_command`: (command, output, exit code); output and the
    /// exit line are both optional.
    static func splitCommand(_ content: String) -> (command: String, output: String, exitCode: Int?) {
        let trimmed = content.rustTrimmed
        let (first, rest): (String, String)
        if let newline = trimmed.utf8.firstIndex(of: 0x0A) {
            first = String(decoding: trimmed.utf8[..<newline], as: UTF8.self)
            rest = String(decoding: trimmed.utf8[trimmed.utf8.index(after: newline)...], as: UTF8.self)
        } else {
            (first, rest) = (trimmed, "")
        }
        var cmd = Substring(first.rustTrimmed)
        while cmd.utf8.first == UInt8(ascii: "$") { cmd = cmd.dropFirst() }
        var output = rest.rustTrimEnd
        var exitCode: Int?
        if let marker = output.range(of: "[exit: ", options: [.literal, .backwards]) {
            let tail = output[marker.upperBound...]
            if tail.utf8.last == UInt8(ascii: "]"), let code = Int(String(tail.dropLast()).rustTrimmed) {
                exitCode = code
                output = String(output[..<marker.lowerBound]).rustTrimEnd
            }
        }
        return (String(cmd).rustTrimmed, output, exitCode)
    }
}
