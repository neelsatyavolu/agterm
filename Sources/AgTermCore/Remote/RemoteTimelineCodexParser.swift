import Foundation

/// The parts of agmux `parse_session_history_content` that produce timeline
/// rows. Not ported: code-mode `exec` wrappers that embed `tools.apply_patch`
/// (agmux decodes them into file rows and dedups them against native patch
/// events); here those edits come only from the native `patch_apply_end` /
/// `item_completed` FileChange records.
struct CodexHistoryParser {
    private struct PendingCommand { let index: Int; let cmd: String }
    private struct PendingPatch { let timestamp: String; let changes: [CodexFileChange] }

    private var items: [CodexHistoryItem] = []
    private var pendingPatches: [String: PendingPatch] = [:]
    private var pendingCommands: [String: PendingCommand] = [:]
    private var patchApplyEndIDs: Set<String> = []
    private var nativePatchIDs: Set<String> = []

    static func items(rollout: String) -> [CodexHistoryItem] {
        var parser = CodexHistoryParser()
        let records = rustLines(rollout).compactMap { line -> JSONValue? in
            let trimmed = line.rustTrimmed
            return trimmed.isEmpty ? nil : JSONValue.parse(trimmed)
        }
        // Native patch ids anywhere in the file: a direct apply_patch output is
        // superseded by its native event even when the event comes later.
        for record in records where record["type"]?.string == "event_msg" {
            if let native = record["payload"].flatMap(CodexHistoryRows.nativePatchEvent),
               let id = native["call_id"]?.string, !id.isEmpty {
                parser.nativePatchIDs.insert(id)
            }
        }
        for record in records { parser.consume(record) }
        return parser.deduplicated()
    }

    private mutating func consume(_ record: JSONValue) {
        guard let payload = record["payload"] else { return }
        let ts = record["timestamp"]?.string ?? ""
        switch record["type"]?.string {
        case "event_msg": consumeEvent(CodexHistoryRows.nativePatchEvent(payload) ?? payload, ts)
        case "response_item": consumeResponse(payload, ts)
        default: break
        }
    }

    private mutating func consumeEvent(_ payload: JSONValue, _ ts: String) {
        switch payload["type"]?.string {
        case "user_message":
            if let text = payload["message"]?.string { items.append(CodexHistoryItem(role: "user", content: text, timestamp: ts)) }
        case "patch_apply_end":
            let callID = payload["call_id"]?.string ?? ""
            if !callID.isEmpty && patchApplyEndIDs.contains(callID) { return }
            let changes = CodexHistoryRows.changesFromPatchApplyEnd(payload)
            if !callID.isEmpty {
                patchApplyEndIDs.insert(callID)
                pendingPatches[callID] = nil
            }
            guard payload["success"]?.bool == true else { return }
            items += changes.map { CodexHistoryItem.file($0, ts, editID: callID, native: true) }
        default:
            break
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private mutating func consumeResponse(_ payload: JSONValue, _ ts: String) {
        let callID = payload["call_id"]?.string ?? ""
        switch payload["type"]?.string ?? "" {
        case "message":
            guard let content = payload["content"]?.array else { return }
            let text = content.compactMap { block -> String? in
                let type = block["type"]?.string
                return type == "output_text" || type == "input_text" ? block["text"]?.string : nil
            }.joined()
            let role = payload["role"]?.string ?? ""
            // Developer/system messages are AGENTS.md, permissions and memory setup.
            guard !text.isEmpty, role != "developer", role != "system" else { return }
            items.append(CodexHistoryItem(role: role == "user" ? "user" : "assistant", content: text, timestamp: ts))
        case "function_call":
            let name = payload["name"]?.string ?? "unknown"
            let args = payload["arguments"]?.string ?? ""
            if name == "exec_command" {
                guard let parsed = JSONValue.parse(args) else { return }
                let cmd = parsed["cmd"]?.string ?? args
                if !callID.isEmpty { pendingCommands[callID] = PendingCommand(index: items.count, cmd: cmd) }
                items.append(CodexHistoryItem(role: "command", content: "$ \(cmd)", timestamp: ts))
            } else {
                appendTool(payload, ts)
            }
        case "custom_tool_call":
            let name = payload["name"]?.string ?? ""
            let input = payload["input"]?.string ?? ""
            if !callID.isEmpty && (name == "apply_patch" || name == "apply_patch_freeform") && !input.isEmpty {
                let changes = CodexHistoryRows.applyPatchChanges(input)
                if !changes.isEmpty { pendingPatches[callID] = PendingPatch(timestamp: ts, changes: changes) }
            } else {
                appendTool(payload, ts)
            }
        case "custom_tool_call_output":
            consumeCustomOutput(payload, callID, ts)
        case "function_call_output":
            if !callID.isEmpty, let pending = pendingCommands.removeValue(forKey: callID) {
                completeCommand(pending, payload)
            } else {
                appendTool(payload, ts)
            }
        case "reasoning":
            if let text = CodexHistoryRows.reasoningSummary(payload) {
                items.append(CodexHistoryItem(role: "thinking", content: text, timestamp: ts))
            }
        default:
            appendTool(payload, ts)
        }
    }

    private mutating func consumeCustomOutput(_ payload: JSONValue, _ callID: String, _ ts: String) {
        // Already counted from this call's native patch event.
        if !callID.isEmpty && patchApplyEndIDs.contains(callID) {
            pendingPatches[callID] = nil
            return
        }
        if pendingPatches[callID] != nil && nativePatchIDs.contains(callID) { return }
        guard !callID.isEmpty, let pending = pendingPatches.removeValue(forKey: callID) else {
            appendTool(payload, ts)
            return
        }
        let output = payload["output"]?.string ?? ""
        // Only a confirmed exit 0 turns a direct patch into file rows.
        guard JSONValue.parse(output)?.pointer("/metadata/exit_code")?.int == 0 else {
            appendTool(payload, ts)
            return
        }
        let stamp = ts.isEmpty ? pending.timestamp : ts
        items += pending.changes.map { CodexHistoryItem.file($0, stamp, editID: callID, native: false) }
    }

    private mutating func completeCommand(_ pending: PendingCommand, _ payload: JSONValue) {
        let raw = payload["output"]?.string ?? ""
        var text = raw
        var exitCode: Int?
        if let parsed = JSONValue.parse(raw) {
            text = parsed["output"]?.string ?? raw
            exitCode = (parsed["exit_code"] ?? parsed.pointer("/metadata/exit_code"))?.int
        }
        guard pending.index < items.count else { return }
        let trimmed = text.rustTrimmed
        let status = exitCode.map { "\n[exit: \($0)]" } ?? ""
        items[pending.index].content = trimmed.isEmpty ? "$ \(pending.cmd)\(status)" : "$ \(pending.cmd)\n\(trimmed)\(status)"
    }

    private mutating func appendTool(_ payload: JSONValue, _ ts: String) {
        if let item = CodexHistoryRows.toolItem(payload, ts) { items.append(item) }
    }

    /// Drops consecutive duplicates (the same prompt arrives as `event_msg`
    /// and `response_item`); tool and file rows keep their call identity.
    private func deduplicated() -> [CodexHistoryItem] {
        items.reduce(into: []) { out, item in
            if let last = out.last, item.role != "file", item.role != "tool",
               last.role == item.role, last.content == item.content { return }
            out.append(item)
        }
    }
}
